-module(hackney_pooler).

-export([new_pool/2]).
-export([request/3, request/4, request/5, request/6]).


%% internal methods
-export([istart_link/1, init/2,
         system_continue/3, system_terminate/4, system_code_change/4]).

-record(state, {parent, hpool}).


-define(HCALL(Pid, Req), {'$hackney_call', Pid, Req}).

new_pool(Name, Config) ->
    %% maybe initiaalise the Hackney connections pool
    HPool = case proplists:get_value(hackney_pool, Config) of
                undefined ->
                    Group = proplists:get_value(group, Config),
                    MaxConn = proplists:get_value(max_count, Config,
                                                  50),
                    PoolName = Group,
                    PoolHandler = hackney_app:get_app_env(pool_handler,
                                                          hackney_pool),
                    %% start Hackney pool
                    HConfig =  [{max_connections, MaxConn}],
                    PoolHandler:start_pool(PoolName, HConfig),
                    PoolName;
                PoolName ->
                    PoolName
            end,

    %% start worker pool
    Config1 = [{name, Name} |Config],
    PoolConfig = Config1 ++ [{start_mfa,
                              {?MODULE, istart_link, [HPool]}}],
    pooler:new_pool(PoolConfig).


%% @doc make a request
-spec request(atom(), term(), binary()|list())
    -> {ok, integer(), list(), binary()} | {error, term()}.
request(PoolName, Method, URL) ->
    request(PoolName, Method, URL, [], <<>>, []).

%% @doc make a request
-spec request(atom(), term(), binary()|list(), list())
    -> {ok, integer(), list(), binary()} | {error, term()}.
request(PoolName, Method, URL, Headers) ->
    request(PoolName, Method, URL, Headers, <<>>, []).

%% @doc make a request
-spec request(atom(), term(), binary()|list(), list(), term())
    -> {ok, integer(), list(), binary()} | {error, term()}.
request(PoolName, Method, URL, Headers, Body) ->
    request(PoolName, Method, URL, Headers, Body, []).


-spec request(atom(), term(), binary()|list(), list(), term(), list())
    -> {ok, integer(), list(), binary()} | {error, term()}.
request(PoolName, Method, URL, Headers, Body, Options) ->
    Proc = pooler:take_member(PoolName),
    try
        req(Proc, {request, Method, URL, Headers, Body, Options})
    after
        pooler:return_member(PoolName, Proc, ok)
    end.



req(Proc, R) ->
    Ref = erlang:monitor(process, Proc),
    Proc ! ?HCALL(self(), R),
    receive
	{'DOWN', Ref, process, Proc, _Info} ->
            badarg;
	{Proc, Reply} ->
	    erlang:demonitor(Ref, [flush]),
	    Reply
    end.


istart_link(HPool) ->
    {ok, proc_lib:spawn_link(hackney_pooler, init, [self(), HPool])}.


init(Parent, HPool) ->
    process_flag(trap_exit, true),
    pooler_loop(#state{parent=Parent, hpool=HPool}).



pooler_loop(#state{parent=Parent, hpool=Hpool}=State) ->
    receive
        ?HCALL(From, {request, Method, Url, Headers, Body, Options}) ->
            do_request(From, Hpool, Method, Url, Headers, Body, Options);
        {'EXIT', Parent, Reason} ->
			terminate(Reason, State),
            exit(Reason);
        {system, From, Req} ->
            sys:handle_system_msg(Req, From, Parent, ?MODULE, [], State);
        Message ->
            error_logger:format("** hackney_pooler: unexpected message"
                                "(ignored): ~w~n", [Message]),
            pooler_loop(State)
    end.


do_request(From, HPool,  Method, Url, Headers, Body, Options) ->
    %% pass the pool to the config.
    Options1 = [{pool, HPool} | Options],
    %% do the request
    Reply = case hackney:request(Method, Url, Headers, Body, Options1) of
                {ok, Status, RespHeaders, Ref} ->
                    erlang:put(req, Ref),
                    case hackney:body(Ref) of
                        {ok, RespBody} -> {ok, Status, RespHeaders, RespBody};
                        Error -> Error
                    end;
                {ok, Status, RespHeaders} ->
                    {ok, Status, RespHeaders, <<>>};
                Error ->
                    Error
            end,
    %% send the reply
    From ! {self(), Reply},
    ok.


terminate(_Reason, _State) ->
    %% if a request is running, force close
    case erlang:get(req) of
        undefined -> ok;
        Ref ->
            hackney:close(Ref)
    end.


%%-----------------------------------------------------------------
%% Callback functions for system messages handling.
%%-----------------------------------------------------------------
system_continue(_Parent, _, State) ->
    pooler_loop(State).

system_terminate(Reason, _Parent, _, State) ->
    terminate(Reason, State),
    exit(Reason).

%%-----------------------------------------------------------------
%% Code for upgrade.
%%-----------------------------------------------------------------
system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.
