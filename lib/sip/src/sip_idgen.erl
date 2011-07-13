%%%----------------------------------------------------------------
%%% @author  Ivan Dubrov <wfragg@gmail.com>
%%% @doc Utilities to generate different identifiers (branch, tags)
%%%
%%% @end
%%% @copyright 2011 Ivan Dubrov
%%%----------------------------------------------------------------
-module(sip_idgen).

%% Exports

%% API
-export([generate_tag/0, generate_branch/0, generate_call_id/0]).

%% Include files
-include_lib("sip.hrl").

%%-----------------------------------------------------------------
%% API functions
%%-----------------------------------------------------------------

%% @doc Generate new random tag binary
%%
%% When a tag is generated by a UA for insertion into a request or
%% response, it MUST be globally unique and cryptographically random
%% with at least 32 bits of randomness.
%% @end
-spec generate_tag() -> binary().
generate_tag() ->
    rand_binary(16, <<>>).

%% @doc Generate new random tag branch
%%
%% The branch parameter value MUST be unique across space and time for
%% all requests sent by the UA.
%% @end
-spec generate_branch() -> binary().
generate_branch() ->
    rand_binary(8, <<?MAGIC_COOKIE>>).

%% @doc Generate new random Call-ID
%%
%% In a new request created by a UAC outside of any dialog, the Call-ID
%% header field MUST be selected by the UAC as a globally unique
%% identifier over space and time unless overridden by method-specific
%% behavior.
%% @end
-spec generate_call_id() -> binary().
generate_call_id() ->
    rand_binary(8, <<>>).


%%-----------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------
rand_binary(0, Bin) -> Bin;
rand_binary(N, Bin) ->
    Char =
        case crypto:rand_uniform(0, 52) of
            C when C < 26 -> C + $a;
            C -> C - 26 + $A
        end,
    rand_binary(N - 1, <<Bin/binary, Char>>).
