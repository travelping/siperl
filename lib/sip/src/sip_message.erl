%%%----------------------------------------------------------------
%%% @author  Ivan Dubrov <wfragg@gmail.com>
%%% @doc
%%% SIP messages parsing/generation.
%%% @end
%%% @copyright 2011 Ivan Dubrov
%%%----------------------------------------------------------------
-module(sip_message).

%%-----------------------------------------------------------------
%% Exports
%%-----------------------------------------------------------------
-export([is_request/1, is_response/1, to_binary/1]).
-export([is_provisional_response/1]).
-export([parse_stream/2, parse_datagram/1, parse_whole/1, normalize/1]).
-export([request/2, response/2]).
-export([create_ack/2, create_response/4]).

%%-----------------------------------------------------------------
%% Macros
%%-----------------------------------------------------------------
-define(SIPVERSION, "SIP/2.0").

%%-----------------------------------------------------------------
%% Include files
%%-----------------------------------------------------------------
-include_lib("sip_common.hrl").
-include_lib("sip_message.hrl").

%% Types

%% Internal state
%% 'BEFORE' -- state before Start-Line
%% 'HEADERS' -- state after first Start-Line character was received
%% {'BODY', StartLine, Headers, Length} -- state after receiving headers, but before body (\r\n\r\n)
-type state() :: {'BEFORE' | 'HEADERS' | {'BODY', start_line(), [sip_headers:header()], integer()}, binary()}.

%% Exported types
-type start_line() :: {'request', Method :: sip_headers:method(), RequestURI :: binary()} |
					  {'response', Status :: integer(), Reason :: binary()}.
-export_type([start_line/0]).

%%-----------------------------------------------------------------
%% API functions
%%-----------------------------------------------------------------

%% @doc
%% Check if message is SIP request.
%% @end
-spec is_request(#sip_message{}) -> boolean().
is_request(#sip_message{start_line = {request, _, _}}) ->
	true;

is_request(#sip_message{start_line = {response, _, _}}) ->
	false.

%% @doc
%% Check if message is SIP response.
%% @end
-spec is_response(#sip_message{}) -> boolean().
is_response(Message) ->
	not is_request(Message).

%% @doc
%% Check if message is SIP provisional response (1xx).
%% @end
-spec is_provisional_response(#sip_message{}) -> boolean().
is_provisional_response(#sip_message{start_line = {response, Status, _}}) 
  when Status >= 100, Status =< 199 ->
	true;

is_provisional_response(#sip_message{start_line = {response, _Status, _}}) ->
	false.

-spec to_binary(#sip_message{}) -> binary().
to_binary(Message) ->
	Top = case Message#sip_message.start_line of
			  {request, Method, URI} -> <<(sip_binary:any_to_binary(Method))/binary, " ", URI/binary, " ", ?SIPVERSION>>;
			  {response, Status, Reason} ->
				  StatusStr = list_to_binary(integer_to_list(Status)),
				  <<?SIPVERSION, " ", StatusStr/binary, " ", Reason/binary>>
		  end,
	Headers = lists:map(fun sip_headers:format_header/1, Message#sip_message.headers),
	iolist_to_binary([Top, <<"\r\n">>, Headers, <<"\r\n">>, Message#sip_message.body]).

-spec parse_datagram(Datagram :: binary()) -> 
		  {ok, #sip_message{}}
		| {bad_request, Reason :: term()} 
		| {bad_response, Reason :: term()}.
%% @doc
%% Parses the datagram for SIP packet. The headers of the returned message are
%% retained in binary form for performance reasons. Use {@link parse_whole/1}
%% to parse the whole message or {@link sip_headers:parse_header/2} to parse
%% single header.
%% @end
parse_datagram(Datagram) ->
	[Top, Body] = binary:split(Datagram, <<"\r\n\r\n">>),
	[Start | Tail] = binary:split(Top, <<"\r\n">>),
	Headers = case Tail of
				  [] -> [];
				  [Bin] -> sip_headers:split_binary(Bin)
			  end,
	StartLine = parse_start_line(Start),

	% RFC 3261 18.3
	case get_content_length(Headers) of
		false ->
			{ok, #sip_message{start_line = StartLine, headers = Headers, body = Body}};

		% Content-Length is present
		{ok, ContentLength} when ContentLength =< size(Body) ->
			<<Body2:ContentLength/binary, _/binary>> = Body,
			{ok, #sip_message{start_line = StartLine, headers = Headers, body = Body2}};
			
		{ok, _} when element(1, StartLine) =:= request ->
			{bad_request, content_too_small};

		{ok, _} ->
			{bad_response, content_too_small}
	end.

-spec parse_stream(Packet :: binary(), State :: state() | 'none') -> 
		  {ok, state(), Msgs :: [#sip_message{}]}
        | {'bad_request', Reason :: term()}
	    | {'bad_response', Reason :: term()}. 
			  
%% @doc
%% Parses the stream for complete SIP messages. Return new parser state
%% and list of complete messages extracted from the stream. The headers
%% of the returned messages are retained in binary form for performance
%% reasons. Use {@link parse_whole/1} to parse the whole message or
%% {@link sip_headers:parse_header/2} to parse single header.
%% @end
parse_stream(Packet, none) ->
	parse_stream(Packet, {'BEFORE', <<>>});

parse_stream(Packet, {State, Frame}) when is_binary(Packet) ->
	NewFrame = <<Frame/binary, Packet/binary>>,
	case pre_parse_stream({State, NewFrame}, size(Frame), []) of
		{ok, NewState, Msgs} ->	
			{ok, NewState, lists:reverse(Msgs)};
		
		Error -> 
			Error
	end.


%% @doc
%% Parses all headers of the message.
%% @end
-spec parse_whole(#sip_message{}) -> #sip_message{}. 
parse_whole(Msg) when is_record(Msg, sip_message) ->
	Headers = [sip_headers:parse_header(Name, Value) || {Name, Value} <- Msg#sip_message.headers],
	Msg#sip_message{headers = Headers}.

%% @doc
%% Parse and stable sort all headers of the message. This function is mostly used for testing
%% purposes before comparing the messages.
%% @end
-spec normalize(#sip_message{}) -> #sip_message{}.
normalize(Msg) when is_record(Msg, sip_message) ->
	Msg2 = parse_whole(Msg),
	Msg2#sip_message{headers = lists:keysort(1, Msg2#sip_message.headers)}.

%%-----------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------

%% RFC 3261 7.5  Implementations processing SIP messages over
%% stream-oriented transports MUST ignore any CRLF appearing before the
%% start-line
pre_parse_stream({'BEFORE', <<"\r\n", Rest/binary>>}, _, Msgs) ->
	pre_parse_stream({'BEFORE', Rest}, 0, Msgs);

%% Frame is empty or "\r" while ignoring \r\n, return same state
pre_parse_stream({'BEFORE', Frame}, _, Msgs) when Frame =:= <<"\r">>; Frame =:= <<>> ->
	{ok, {'BEFORE', Frame}, Msgs};

%% Look for headers-body delimiter
pre_parse_stream({State, Frame}, From, Msgs) when State =:= 'HEADERS'; State =:= 'BEFORE'->
	% Search if header-body delimiter is present
	% We need to look back 3 characters at most 
	% (last frame ends with \r\n\r, we have received \n) 
	case has_header_delimiter(Frame, From - 3) of
		false -> 
			{ok, {'HEADERS', Frame}, Msgs};
					   
		Pos ->
			% Split packet into headers and the rest 
			<<Top:Pos/binary, _:4/binary, Rest/binary>> = Frame,
			
			% Get start line and headers
			[Start|Tail] = binary:split(Top, <<"\r\n">>),
			Headers = case Tail of
						  [] -> [];
						  [Bin] -> sip_headers:split_binary(Bin)
					  end,
			StartLine = parse_start_line(Start),
			
			% Check content length present
			case get_content_length(Headers) of
				{ok, ContentLength} ->
					% Continue processing the message body
					NewState = {'BODY', StartLine, Headers,ContentLength},
					pre_parse_stream({NewState, Rest}, 0, Msgs);
				
				false when element(1, StartLine) =:= request -> 
					{bad_request, no_content_length};
				
				false -> 
					{bad_response, no_content_length}
			end
	end;

%% Check if we have received the whole body
pre_parse_stream({{'BODY', StartLine, Headers, ContentLength}, Frame}, _, Msgs) 
  when size(Frame) >= ContentLength ->
	
	<<Body:ContentLength/binary, Rest/binary>> = Frame,	
	
	% Process the received packet
	NewMsgs = [#sip_message{start_line = StartLine, headers = Headers, body = Body} | Msgs], 
	
	% Continue processing the remaining data as it were a new packet
	pre_parse_stream({'BEFORE', Rest}, 0, NewMsgs);

%% Nothing to parse yet, return current state
pre_parse_stream(State, _, Msgs) ->
	{ok, State, Msgs}.
	
%% Check if we have header-body delimiter in the received packet
has_header_delimiter(Data, Offset) when Offset < 0 ->
	has_header_delimiter(Data, 0);

has_header_delimiter(Data, Offset) ->
	case binary:match(Data, <<"\r\n\r\n">>, [{scope, {Offset, size(Data) - Offset}}]) of
		nomatch -> false;
		{Pos, _} -> Pos
	end.

get_content_length(Headers) ->
	case lists:keyfind('content-length', 1, Headers) of
		{_, ContentLength} -> 
			{ok, sip_binary:to_integer(ContentLength)};
		false ->
			false
	end.

%% Request-Line   =  Method SP Request-URI SP SIP-Version CRLF
%% Status-Line  =  SIP-Version SP Status-Code SP Reason-Phrase CRLF
%% start-line   =  Request-Line / Status-Line
%%
%% RFC3261 7.1: The SIP-Version string is case-insensitive, but implementations MUST send upper-case.
-spec parse_start_line(binary()) -> start_line().
parse_start_line(StartLine) when is_binary(StartLine) ->
	case binary:split(StartLine, <<" ">>, [global]) of		
		[Method, RequestURI, <<?SIPVERSION>>] 
		  ->
			{request, sip_binary:try_binary_to_existing_atom(sip_binary:to_upper(Method)), RequestURI};
		
		[<<?SIPVERSION>>, <<A,B,C>>, ReasonPhrase] when 
			$1 =< A andalso A =< $6 andalso % 1xx - 6xx
			$0 =< B andalso B =< $9 andalso
			$0 =< C andalso C =< $9 
		  ->
			{response, list_to_integer([A, B, C]), ReasonPhrase}
	end.

%% @doc
%% Request start line construction. 
%% @end
-spec request(sip_headers:method(), binary()) -> {'request', Method :: sip_headers:method(), RequestURI :: binary()}.
request(Method, RequestURI) 
  when is_binary(RequestURI), (is_atom(Method) orelse is_binary(Method)) ->
	{request, Method, RequestURI}.

%% @doc
%% Response start line construction. 
%% @end
-spec response(integer(), binary()) -> {'response', Status :: integer(), Reason :: binary()}.
response(Status, Reason) 
  when is_integer(Status), is_binary(Reason) ->
	{response, Status, Reason}.

%% @doc
%% RFC 3261, 17.1.1.3 Construction of the ACK Request
%% @end
-spec create_ack(#sip_message{}, #sip_message{}) -> #sip_message{}.
create_ack(Request, Response) when is_record(Request, sip_message), 
								   is_record(Response, sip_message) ->
	{request, Method, RequestURI} = Request#sip_message.start_line,
	
	% Call-Id, From, CSeq (with method changed to 'ACK') and Route (for 'INVITE' 
	% response ACKs) are taken from the original request
	FoldFun = fun ({'call-id', _} = H, List) -> [H|List];
			      ({'from', _} = H, List) -> [H|List];
			      ({'cseq', Value}, List) ->
					   {_, CSeq} = sip_headers:parse_header('cseq', Value),
					   CSeq2 = {'cseq', CSeq#sip_hdr_cseq{method = 'ACK'}},
					   [CSeq2|List];
			      ({'route', _} = H, List) when Method =:= 'INVITE' -> [H|List];
				  (_, List) -> List
		   end,	
	ReqHeaders = lists:reverse(lists:foldl(FoldFun, [], Request#sip_message.headers)),
	
	% Via is taken from top Via of the original request
	Via = {'via', [sip_headers:top_via(Request#sip_message.headers)]},

	% To goes from the response 
	{'to', To} = lists:keyfind('to', 1, Response#sip_message.headers),
	
	#sip_message{start_line = {request, 'ACK', RequestURI},
				 body = <<>>,
				 headers = [Via, {'to', To} | ReqHeaders]}.


%% @doc
%% 8.2.6.1 Sending a Provisional Response
%% FIXME: adding tag...
%% @end
-spec create_response(#sip_message{}, integer(), binary(), binary()) -> #sip_message{}.
create_response(Request, Status, Reason, Tag) ->
	Headers = [if Name =:= 'to' -> add_tag({Name, Value}, Tag);
				  true -> {Name, Value}
			   end || {Name, Value} <- Request#sip_message.headers,
					  (Name =:= 'from' orelse Name =:= 'call-id' orelse
					   Name =:= 'cseq' orelse Name =:= 'via' orelse
					   Name =:= 'to')],
	Start = {response, Status, Reason},
	#sip_message{start_line = Start, headers = Headers}.

add_tag(Header, undefined) ->
	Header;
add_tag({Name, Value}, Tag) 
  when Name =:= 'to' orelse Name =:= 'from' ->
	{Name2, Value2} = sip_headers:parse_header(Name, Value),
	
	Params = lists:keystore('tag', 1, Value2#sip_hdr_address.params, {'tag', Tag}),
	{Name2, Value2#sip_hdr_address{params = Params}}.

%%-----------------------------------------------------------------
%% Tests
%%-----------------------------------------------------------------
-ifndef(NO_TEST).

-spec parse_request_line_test_() -> term().
parse_request_line_test_() ->
    [?_assertEqual({request, 'INVITE', <<"sip:bob@biloxi.com">>}, 
				   parse_start_line(<<"INVITE sip:bob@biloxi.com SIP/2.0">>)),
	 ?_assertException(error, {case_clause, _}, parse_start_line(<<"INV ITE sip:bob@biloxi.com SIP/2.0">>)), 
	 ?_assertEqual({response, 200, <<"OK">>},
				   parse_start_line(<<"SIP/2.0 200 OK">>)),
	 ?_assertException(error, {case_clause, _}, parse_start_line(<<"SIP/2.0 099 Invalid">>))
    ].

-spec parse_stream_test_() -> term().
parse_stream_test_() ->
	StartState = {'BEFORE', <<>>},
	SampleRequest = {request, 'INVITE', <<"sip:urn:service:test">>},
	SampleMessage = #sip_message{start_line = SampleRequest,
								 headers = [{'content-length', <<"5">>}],
								 body = <<"Hello">>},	
    [ %% Skipping \r\n
	 ?_assertEqual({ok, StartState, []}, 
				   parse_stream(<<>>, none)),
	 ?_assertEqual({ok, StartState, []}, 
				   parse_stream(<<"\r\n">>, none)),
	 ?_assertEqual({ok, {'BEFORE', <<"\r">>}, []}, 
				   parse_stream(<<"\r">>, none)),

	 % Test headers-body delimiter test 	 
	 ?_assertEqual({ok, {'HEADERS', <<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r">>}, []}, 
				   parse_stream(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r">>, none)),
	 
	 ?_assertEqual({ok, {{'BODY', SampleRequest, [{'content-length', <<"5">>}], 5}, <<>>}, []}, 
				   parse_stream(<<"\n">>, 
								{'HEADERS', <<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r">>})),
	 
	 ?_assertEqual({ok, {{'BODY', SampleRequest, [{'content-length', <<"5">>}], 5}, <<"He">>}, []}, 
				   parse_stream(<<"He">>, 
								{{'BODY', SampleRequest, [{'content-length', <<"5">>}], 5}, <<>>})),
	 
	 % Parse the whole body	 
	 ?_assertEqual({ok, StartState, [SampleMessage]}, 
				   parse_stream(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r\nHello">>, none)),
	 ?_assertEqual({ok, StartState, [SampleMessage]}, 
				   parse_stream(<<"Hello">>, 
								{{'BODY', SampleRequest, [{'content-length', <<"5">>}], 5}, <<>>})),	 
	 ?_assertEqual({ok, StartState, 
					[SampleMessage#sip_message{headers = [{<<"x-custom">>, <<"Nothing">>}, {'content-length', <<"5">>}]}]}, 
				   parse_stream(<<"INVITE sip:urn:service:test SIP/2.0\r\nX-Custom: Nothing\r\nContent-Length: 5\r\n\r\nHello">>, 
								StartState)),
	 
	 % No Content-Length
	 ?_assertEqual({bad_request, no_content_length}, 
				   parse_stream(<<"INVITE sip:urn:service:test SIP/2.0\r\nX-Custom: Nothing\r\n\r\nHello">>, StartState)),
	 ?_assertEqual({bad_response, no_content_length}, 
				   parse_stream(<<"SIP/2.0 200 Ok\r\n\r\n">>, StartState))
    ].

-spec parse_datagram_test_() -> term().
parse_datagram_test_() ->
	SampleRequest = {request, 'INVITE', <<"sip:urn:service:test">>},
	SampleMessage = #sip_message{start_line = SampleRequest,
								 headers = [{'content-length', <<"5">>}],
								 body = <<"Hello">>},	
    [
	 % Parse the whole body	 
	 ?_assertEqual({ok, SampleMessage}, 
				   parse_datagram(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\n\r\nHello">>)),
	 ?_assertEqual({ok, SampleMessage#sip_message{headers = [{<<"x-custom">>, <<"Nothing">>}, {'content-length', <<"5">>}]}}, 
				   parse_datagram(<<"INVITE sip:urn:service:test SIP/2.0\r\nX-Custom: Nothing\r\nContent-Length: 5\r\n\r\nHello!!!">>)),
	 
	 % Message too small
	 ?_assertEqual({bad_request, content_too_small}, 
				   parse_datagram(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 10\r\n\r\nHello">>)),
	 ?_assertEqual({bad_response, content_too_small}, 
				   parse_datagram(<<"SIP/2.0 200 Ok\r\nContent-Length: 10\r\n\r\n">>)),
	 
	 % No Content-Length
	 ?_assertEqual({ok, #sip_message{start_line = SampleRequest, 
									 headers = [{<<"x-custom">>, <<"Nothing">>}],
									 body = <<"Hello">> } }, 
				   parse_datagram(<<"INVITE sip:urn:service:test SIP/2.0\r\nX-Custom: Nothing\r\n\r\nHello">>)),
	 ?_assertEqual({ok, #sip_message{start_line = {response, 200, <<"Ok">>} } }, 
				   parse_datagram(<<"SIP/2.0 200 Ok\r\n\r\n">>))
    ].

-spec is_test_() -> term().
is_test_() ->
	{ok, _, [Request]} = parse_stream(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\nX-Custom: Nothing\r\n\r\nHello">>, none),
	{ok, _, [Response]} = parse_stream(<<"SIP/2.0 200 Ok\r\nContent-Length: 5\r\n\r\nHello">>, none),
	{ok, ProvResponse} = parse_datagram(<<"SIP/2.0 100 Trying\r\n\r\n">>),
    [?_assertEqual(true, is_request(Request)),
	 ?_assertEqual(false, is_request(Response)),
	 ?_assertEqual(false, is_response(Request)),
	 ?_assertEqual(true, is_response(Response)),
	 ?_assertEqual(true, is_provisional_response(ProvResponse)),
	 ?_assertEqual(false, is_provisional_response(Response)),
	 ?_assertEqual(<<"INVITE sip:urn:service:test SIP/2.0\r\nContent-Length: 5\r\nx-custom: Nothing\r\n\r\nHello">>, to_binary(Request)),
	 ?_assertEqual(<<"SIP/2.0 200 Ok\r\nContent-Length: 5\r\n\r\nHello">>, to_binary(Response))
    ].


-spec create_ack_test_() -> list().
create_ack_test_() ->
	ReqHeaders = [
				  {'via', <<"SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bKkjshdyff">>},
				  {'to', <<"Bob <sip:bob@biloxi.com>">>},
				  {'from', <<"Alice <sip:alice@atlanta.com>;tag=88sja8x">>},
				  {'call-id', <<"987asjd97y7atg">>},
				  {'cseq', <<"986759 INVITE">>},
				  {'route', <<"<sip:alice@atlanta.com>">>},
				  {'route', <<"<sip:bob@biloxi.com>">>}
				  ],	
	OrigRequest = #sip_message{start_line = request('INVITE', <<"sip:bob@biloxi.com">>), headers = ReqHeaders},
	
	RespHeaders = lists:keyreplace('to', 1, ReqHeaders, {'to', <<"Bob <sip:bob@biloxi.com>;tag=1928301774">>}),
	Response = #sip_message{start_line = response(500, <<"Internal error">>), headers = RespHeaders},
	
	ACKHeaders = lists:keyreplace('cseq', 1, RespHeaders, {'cseq', <<"986759 ACK">>}),
	ACK = #sip_message{start_line = request('ACK', <<"sip:bob@biloxi.com">>), headers = ACKHeaders},
	[
	 ?_assertEqual(normalize(ACK), normalize(create_ack(OrigRequest, Response)))
	 ].

-endif.