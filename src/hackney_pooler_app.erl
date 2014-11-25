-module(hackney_pooler_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    hackney_pooler_sup:start_link().

stop(_State) ->
    ok.
