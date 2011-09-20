%%% @author  Ivan Dubrov <dubrov.ivan@gmail.com>
%%% @doc UAC/UAS server
%%%
%%%
%%% Automatic response handling:
%%% <ul>
%%% <li>If response is redirect (3xx), populate target set with values from
%%% Contact header(s) and send request to next URI from the target set.</li>
%%% <li>If response is 503 (Service Unavailable) or 408 (Request Timeout), try
%%% next IP address (RFC 3263). If no such destinations, try next URI from the
%%% target set. If no URIs in target set, let callback handle the response.</li>
%%% <li>If another failed response is detected, try next URI from target set.
%%% If target set is empty, let callback handle the response.</li>
%%% <li>Otherwise, let UAC callback handle the response.</li>
%%% </ul>
%%% @end
%%% @copyright 2011 Ivan Dubrov. See LICENSE file.
-module(sip_ua).
-compile({parse_transform, do}).

%% API
-export([start_link/2, start_link/3]).
-export([create_request/2, send_request/1, send_request/2, cancel_request/1]). % UAC
-export([create_response/2, create_response/3, send_response/2]). % UAS

%% Server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_info/2, handle_call/3, handle_cast/2]).

%% Include files
-include("../sip_common.hrl").
-include("sip.hrl").

-define(CALLBACK, sip_ua_callback). % Key in the process dictionary for callback module name
-define(UAC, sip_ua_client). % Key in the process dictionary for UAC state
-define(UAS, sip_ua_server). % Key in the process dictionary for UAS state

-type state() :: term().     % Callback module state
-type gen_from() :: {pid(), term()}.

-type callback() ::  sip_ua_client:callback(). % Response callback
-export_type([callback/0]).

%% API

-spec start_link(atom(), module(), term()) -> {ok, pid()} | {error, term()}.
start_link(Name, Callback, Args) ->
    gen_server:start_link(Name, ?MODULE, {Callback, Args}, []).

-spec start_link(module(), term()) -> {ok, pid()} | {error, term()}.
start_link(Callback, Args) ->
    gen_server:start_link(?MODULE, {Callback, Args}, []).

%% @doc Create request outside of the dialog according to the 8.1.1 Generating the Request
%%
%% Creates all required headers of the SIP message: `Via:', `Max-Forwards:',
%% `From:', `To:', `CSeq:', `Call-Id'. Also, adds `Route:' headers
%% if pre-existing route set is configured.
%%
%% Clients are free to modify any part of the request according to their needs.
%% @end
-spec create_request(sip_name(), #sip_hdr_address{} | #sip_dialog_id{}) -> #sip_request{}.
create_request(Method, To) when is_record(To, sip_hdr_address) ->
    sip_ua_client:create_request(Method, To);

%% @doc Create request within the  dialog according to the 12.2.1.1 Generating the Request
%% Clients are free to modify any part of the request according to their needs.
%% @end
create_request(Method, Dialog) when is_record(Dialog, sip_dialog) ->
    sip_ua_client:create_request(Method, Dialog).

%% @doc Create request outside of the dialog according to the 8.2.6 Generating the Response
%% @end
-spec create_response(#sip_request{}, integer()) -> #sip_response{}.
create_response(Request, Status) ->
    sip_ua_server:create_response(Request, Status).

%% @doc Create request outside of the dialog according to the 8.2.6 Generating the Response
%% @end
-spec create_response(#sip_request{}, integer(), binary()) -> #sip_response{}.
create_response(Request, Status, Reason) ->
    sip_ua_server:create_response(Request, Status, Reason).

%% @doc Send the request asynchronously. Responses will be provided via
%% `Callback' function calls.
%% <em>Note: callback function will be evaluated on a different process!</em>
%% <em>Should be called from UAC/UAS process only</em>
%% @end
-spec send_request(sip_message(), callback()) -> {ok, reference()} | {error, no_destinations}.
send_request(Request, Callback) when is_record(Request, sip_request), is_function(Callback, 2) ->
    UAC = erlang:get(?UAC),
    {Reply, UAC2} = sip_ua_client:send_request(Request, Callback, UAC),
    erlang:put(?UAC, UAC2),
    Reply.

%% @doc Send the request asynchronously. Responses will be provided via
%% `{response, Response, Ref}' messages delivered to the caller
%% <em>Should be called from UAC/UAS process only</em>
%% @end
-spec send_request(sip_message()) -> {ok, reference()} | {error, no_destinations}.
send_request(Request) when is_record(Request, sip_request) ->
    Pid = self(),
    send_request(Request, fun(Ref, {ok, Response}) -> Pid ! {response, Response, Ref} end).

-spec cancel_request(reference()) -> ok | {error, no_request}.
%% @doc Cancel the request identified by the reference
%% <em>Note that it is still possible for the client to receive 2xx response
%% on the request that was successfully cancelled. This is due to the inherent
%% race condition present. For example, this could happen if cancel is invoked
%% before UAC have received 2xx response, but after it was sent by the remote side.
%% That means, client should be ready to issue `BYE' when 2xx is received on
%% request it has cancelled.</em>.
%% <em>Should be called from UAC/UAS process only</em>
%% @end
cancel_request(Id) when is_reference(Id) ->
    UAC = erlang:get(?UAC),
    {Reply, UAC2} = sip_ua_client:cancel_request(Id, UAC),
    erlang:put(?UAC, UAC2),
    Reply.

-spec send_response(#sip_request{}, #sip_response{}) -> ok.
send_response(Request, Response) ->
    gen_server:cast(self(), {send_response, Request, Response}).

%%-----------------------------------------------------------------
%% Server callbacks
%%-----------------------------------------------------------------

%% @private
-spec init({module(), term()}) -> {ok, state()}.
init({Callback, Args}) ->
    {ok, UAC} = sip_ua_client:init(Callback),
    {ok, UAS} = sip_ua_server:init(Callback),

    {ok, State} = Callback:init(Args),

    erlang:put(?UAC, UAC),
    erlang:put(?UAS, UAS),
    erlang:put(?CALLBACK, Callback),

    IsApplicable = fun(Msg) -> Callback:is_applicable(Msg) end,
    sip_cores:register_core(#sip_core_info{is_applicable = IsApplicable}),
    {ok, State}.

%% @private
-spec handle_call(term(), gen_from(), state()) -> {stop, {unexpected, term()}, state()}.
handle_call(Req, From, State) ->
    Callback = erlang:get(?CALLBACK),
    Callback:handle_call(Req, From, State).

%% @private
-spec handle_cast(term(), state()) -> {stop, {unexpected, term()}, state()}.
handle_cast({send_response, Request, Response}, State) ->
    UAS = erlang:get(?UAS),
    {ok, State2, UAS2} = sip_ua_server:send_response(Request, Response, State, UAS),
    erlang:put(?UAS, UAS2),
    {noreply, State2};

handle_cast(Cast, State) ->
    {stop, {unexpected, Cast}, State}.

%% @private
-spec handle_info(_, state()) -> {noreply, state()}.
handle_info({tx, _TxKey, {terminated, _Reason}}, State) ->
    % Ignore transaction terminations
    {noreply, State};

handle_info({response, #sip_response{} = Response, #sip_tx_client{} = TxKey}, State) ->
    % pass responses to UAC
    UAC = erlang:get(?UAC),
    {ok, UAC2} = sip_ua_client:handle_response(Response, TxKey, UAC),
    erlang:put(?UAC, UAC2),
    {noreply, State};

handle_info({request, #sip_request{} = Request}, State) ->
    % pass requests to UAS
    UAS = erlang:get(?UAS),
    {ok, State2, UAS2} = sip_ua_server:handle_request(Request, State, UAS),
    erlang:put(?UAS, UAS2),
    {noreply, State2};

handle_info(Info, State) ->
    Callback = erlang:get(?CALLBACK),
    Callback:handle_info(Info, State).

%% @private
-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
