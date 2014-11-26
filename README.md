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
[pooler](https://github.com/seth/pooler).

## Example of a synchronous request:

    1> application:ensure_all_started(hackney_pooler).
    {ok,[asn1,crypto,public_key,ssl,hackney_pooler]}
    2> hackney_pooler:new_pool(test, [{group, api}, {max_count ,50}, {init_count, 10}]).
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

## Example of an asynchronous request:

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

## Known limitations

- Streams are not handled. A body is fetched entirely when the worker return.
- Config is not validated.
- no REST api
