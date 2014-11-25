-module(hackney_pooler_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    %% hackney supervisor
    HackneySup = {hackney_sup, {hackney_sup, start_link, []},
                  permanent, infinity, supervisor, [hackney_sup]},
    %% pooler supervisor
    PoolerSup = {pooler_sup, {pooler_sup, start_link, []},
                 permanent, infinity, supervisor, [pooler_sup]},
    {ok, { {one_for_one, 5, 10}, [HackneySup, PoolerSup]} }.
