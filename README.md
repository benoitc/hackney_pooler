# hackney_pooler


**EXPERIMENTAL CODE** - This code is an experimentation of a futur change in
hackney paradigm. It's only used to prepare coming changes and validate this
pattern in hackney 2.

## Goal:

Experiment an API to limit the number of requests launched concurrently.

Right now hackney is launching as many requests possible whcih means that a
lot of FDs can be used. Also the pool can become a bottleneck when it get too
much requests.

In hackney pooler you will have N concurrent requests where N is the number of
workers in a pool. A pool group is sharing a pool and a pool can be shared
between multiples groups if given in the pool config.

Internally a pool is maintained using
[worker_pool](https://github.com/inaka/worker_pool).

## Example of a synchronous request:

    1> application:ensure_all_started(hackney_pooler).
    {ok,[asn1,crypto,public_key,ssl,hackney_pooler]}
    2> hackney_pooler:new_pool(test, [{workers,1000}, {concurrency, 4},
                                      {max_connections, 150}]).
    {ok,<0.54.0>}
    4> hackney_pooler:request(test, get, <<"https://friendpaste.com">>).
    {ok,200,
        [{<<"Server">>,<<"nginx/0.7.62">>},
         {<<"Date">>,<<"Tue, 25 Nov 2014 09:42:41 GMT">>},
         {<<"Content-Type">>,<<"text/html; charset=utf-8">>},
         {<<"Transfer-Encoding">>,<<"chunked">>},
         {<<"Connection">>,<<"keep-alive">>},
         {<<"Set-Cookie">>,
          <<"FRIENDPASTE_SID=d7ae3781285eb1ec3598a5b220ea78c90e430cb7; expires=Tue, 0"...>>},
         {<<"Access-Control-Allow-Origin">>,<<"None">>},
         {<<"Access-Control-Allow-Credentials">>,<<"true">>},
         {<<"Access-Control-Allow-Methods">>,
          <<"POST, GET, PUT, DELETE, OPTIONS">>},
         {<<"Access-Control-Allow-Headers">>,
          <<"X-Requested-With, X-HTTP-Method-Override, Content-Type, "...>>},
         {<<"Access-Control-Max-Age">>,<<"86400">>}],
        <<"<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n    <meta charset=\"utf-8\"/>\n    <title>Friendpaste - Welcome"...>>}


> Note: by default a pooler is launch with only 1 connection pool. Using the
> `concurrency` option will create N pools of connections whre 2 * N + 1 =
> number of i/o threads. You can force the number of connections pools using
> `{concurrency, N}`.

## Example of an asynchronous request:

An asynchronous request send is like a cast, it handle the request in the
worker and can send the result to a Pid or a function. If a function is given,
it will be handled in the worker.

    1> application:ensure_all_started(hackney_pooler).
    {ok,[asn1,crypto,public_key,ssl,idna,hackney,pooler,
        hackney_pooler]}
        2>  hackney_pooler:new_pool(test, [{group, testing}, {max_count, 50}, {init_count, 50} ]).
    {ok,<0.61.0>}
    3>  hackney_pooler:async_request(test, self(), get, <<"https://friendpaste.com">>, [], <<>>, []).
    ok
    4> flush().
    Shell got {hpool,{test,{ok,200,
        [{<<"Server">>,<<"nginx/0.7.62">>},
        {<<"Date">>,<<"Wed, 26 Nov 2014 11:00:37 GMT">>},
        {<<"Content-Type">>,
            <<"text/html; charset=utf-8">>},
        {<<"Transfer-Encoding">>,<<"chunked">>}, [...]

> An async request can send requests to a pid, a function (arity 1 or 2) or
> nothing if nil is given.

## Pool Configuration via application environment

    % hackneypooler.config
    % Start Erlang as: erl -config pooler
    % -*- mode: erlang -*-
    % hackney_pooler app config
    [
     {hackney_pooler, [
             {pools, [
                      [{name, test},
                       {workers, 1000},
                       {concurrency, true}]
            ]}
    ].


You can also pass default settinsg using the `default_conf` env setting.

## Known limitations

- Streams are not handled. A body is fetched entirely when the worker return.
- Config is not validated.
- no REST api
