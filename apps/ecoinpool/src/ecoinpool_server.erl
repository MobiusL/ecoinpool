
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ecoinpool.
%%
%% ecoinpool is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ecoinpool is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ecoinpool.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(ecoinpool_server).
-behaviour(gen_server).

-include("ecoinpool_db_records.hrl").

-export([start_link/1, reload_config/1, update_worker/2, remove_worker/2, get_worker_notifications/1]).

% Callbacks from ecoinpool_rpc
-export([rpc_request/5, rpc_lp_request/3]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool,
    cdaemon_mod,
    cdaemon_pid,
    worktbl,
    workertbl,
    workerltbl
}).

% Workunit record
-record(workunit, {
    id,
    worker
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(SubpoolId) ->
    gen_server:start_link({global, {subpool, SubpoolId}}, ?MODULE, [SubpoolId], []).

reload_config(Subpool=#subpool{id=Id}) ->
    gen_server:cast({global, {subpool, Id}}, {reload_config, Subpool}).

rpc_request(PID, Responder, Method, Params, Auth) ->
    gen_server:cast(PID, {rpc_request, Responder, Method, Params, Auth}).

rpc_lp_request(PID, Responder, Auth) ->
    gen_server:cast(PID, {rpc_lp_request, Responder, Auth}).

update_worker(SubpoolId, Worker) ->
    gen_server:cast({global, {subpool, SubpoolId}}, {update_worker, Worker}).

remove_worker(SubpoolId, WorkerId) ->
    gen_server:cast({global, {subpool, SubpoolId}}, {remove_worker, WorkerId}).

% Returns a list of sub-pools for which notifications should be sent
% For simple configurations, this just returns the SubpoolId again, but for
% multi-pool-configurations this may return a longer list
get_worker_notifications(SubpoolId) ->
    gen_server:call({global, {subpool, SubpoolId}}, get_worker_notifications).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([SubpoolId]) ->
    io:format("Subpool ~p starting...~n", [SubpoolId]),
    % Trap exit
    process_flag(trap_exit, true),
    % Setup the work table and worker table
    WorkTbl = ets:new(worktbl, [set, protected, {keypos, 2}]),
    WorkerTbl = ets:new(workertbl, [set, protected, {keypos, 3}]),
    WorkerLookupTbl = ets:new(workerltbl, [set, protected]),
    % Get Subpool record; terminate on error
    {ok, Subpool} = ecoinpool_db:get_subpool_record(SubpoolId),
    % Schedule config reload
    gen_server:cast(self(), {reload_config, Subpool}),
    % Schedule workers reload (TODO: move this to reload_config if worker configuration changed)
    gen_server:cast(self(), reload_workers),
    {ok, #state{subpool=#subpool{}, worktbl=WorkTbl, workertbl=WorkerTbl, workerltbl=WorkerLookupTbl}}.

handle_call(get_worker_notifications, _From, State=#state{subpool=Subpool}) ->
    % Returns the sub-pool IDs for which worker changes should be retrieved
    % Note: Currently only returns the own sub-pool ID
    #subpool{id=SubpoolId} = Subpool,
    {reply, [SubpoolId], State};

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast({reload_config, Subpool}, State=#state{subpool=OldSubpool, cdaemon_mod=OldCoinDaemonModule, cdaemon_pid=OldCoinDaemon}) ->
    % Extract config
    #subpool{id=SubpoolId, port=Port, pool_type=PoolType, coin_daemon_config=CoinDaemonConfig} = Subpool,
    #subpool{port=OldPort, coin_daemon_config=OldCoinDaemonConfig} = OldSubpool,
    % Derive the CoinDaemon module name from PoolType + "_coindaemon"
    CoinDaemonModule = list_to_atom(lists:concat([PoolType, "_coindaemon"])),
    
    % Check the RPC settings; if anything goes wrong, terminate
    StartRPC = if
        OldPort =:= Port -> false;
        OldPort =:= undefined -> true;
        true -> ecoinpool_rpc:stop_rpc(OldPort), true
    end,
    ok = if
        StartRPC -> ecoinpool_rpc:start_rpc(Port, self());
        true -> ok
    end,
    
    % Check the CoinDaemon; if anything goes wrong, terminate
    StartCoinDaemon = if
        OldCoinDaemonModule =:= CoinDaemonModule, OldCoinDaemonConfig =:= CoinDaemonConfig -> false;
        OldCoinDaemonModule =:= undefined -> true;
        true -> ecoinpool_server_sup:stop_coindaemon(SubpoolId), true
    end,
    {ok, CoinDaemon} = if
        StartCoinDaemon ->
            case ecoinpool_server_sup:start_coindaemon(SubpoolId, CoinDaemonModule, CoinDaemonConfig) of
                {ok, Pid, _} -> {ok, Pid};
                {ok, Pid} -> {ok, Pid};
                Error -> ecoinpool_rpc:stop_rpc(Port), Error % Fail but close the RPC beforehand
            end;
        true -> {ok, OldCoinDaemon}
    end,
    
    {noreply, State#state{subpool=Subpool, cdaemon_mod=CoinDaemonModule, cdaemon_pid=CoinDaemon}};

handle_cast(reload_workers, State=#state{subpool=#subpool{id=SubpoolId}, workertbl=WorkerTbl, workerltbl=WorkerLookupTbl}) ->
    ets:delete_all_objects(WorkerLookupTbl),
    ets:delete_all_objects(WorkerTbl),
    
    % Note: Currently only retrieves the own sub-pool workers
    lists:foreach(
        fun (Worker=#worker{id=WorkerId, name=WorkerName}) ->
            ets:insert(WorkerLookupTbl, {WorkerId, WorkerName}),
            ets:insert(WorkerTbl, Worker)
        end,
        ecoinpool_db:get_workers_for_subpools([SubpoolId])
    ),
    
    % Register for worker change notifications
    % Note: Currently only sets the own sub-pool ID
    ecoinpool_worker_monitor:set_worker_notifications(SubpoolId, [SubpoolId]),
    
    {noreply, State};

handle_cast({rpc_request, Responder, _Method, _Params, Auth}, State=#state{}) ->
    Responder({ok, list_to_binary(io_lib:print(Auth)), [longpolling]}),
    {noreply, State};

handle_cast({rpc_lp_request, _SubpoolId, _Responder, _Auth}, State=#state{}) ->
    %TODO
    {noreply, State};

handle_cast({update_worker, Worker=#worker{id=WorkerId, name=WorkerName}}, State=#state{workertbl=WorkerTbl, workerltbl=WorkerLookupTbl}) ->
    ets:match(WorkerTbl, #worker{id=WorkerId, _='_'}),
    
    % Check if existing
    case ets:lookup(WorkerLookupTbl, WorkerId) of
        [] -> % Brand new
            io:format("Brand new: ~p~n", [Worker]),
            ets:insert(WorkerLookupTbl, {WorkerId, WorkerName});
        [{_, WorkerName}] -> % Existing and worker name matches
            io:format("Existing and matches: ~p~n", [WorkerId]),
            ok;
        [{_, OldWorkerName}] -> % Existing & name change
            io:format("Name change: ~p - ~p -> ~p~n", [WorkerId, OldWorkerName, WorkerName]),
            ets:delete(WorkerTbl, OldWorkerName),
            ets:insert(WorkerLookupTbl, {WorkerId, WorkerName})
    end,
    
    % Add/Update the record
    ets:insert(WorkerTbl, Worker),
    
    {noreply, State};

handle_cast({remove_worker, WorkerId}, State=#state{workertbl=WorkerTbl, workerltbl=WorkerLookupTbl}) ->
    case ets:lookup(WorkerLookupTbl, WorkerId) of
        [] -> ok;
        [{_, WorkerName}] ->
            ets:delete(WorkerLookupTbl, WorkerId),
            ets:delete(WorkerTbl, WorkerName)
    end,
    {noreply, State};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{subpool=#subpool{id=Id, port=Port}}) ->
    % Stop the RPC
    ecoinpool_rpc:stop_rpc(Port),
    % Unregister notifications
    ecoinpool_worker_monitor:set_worker_notifications(Id, []),
    % We don't need to stop the CoinDaemon, because that will be handled by the supervisor
    io:format("Subpool ~p terminated.~n", [Id]),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
