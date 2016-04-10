-module(http2_frame_headers).

-include("http2.hrl").

-behaviour(http2_frame).

-export(
   [
    format/1,
    from_frames/1,
    new/1,
    new/2,
    read_binary/2,
    to_frames/5,
    to_binary/1
  ]).

-record(headers,
        {
          priority = undefined :: http2_frame_priority:payload() | undefined,
          block_fragment :: binary()
        }).
-type payload() :: #headers{}.
-export_type([payload/0]).

-spec format(payload()) -> iodata().
format(Payload) ->
    io_lib:format("[Headers: ~p]", [Payload]).

-spec new(binary()) -> payload().
new(BlockFragment) ->
    #headers{block_fragment=BlockFragment}.

-spec new(http2_frame_priority:payload(),
          binary()) ->
                 payload().
new(Priority, BlockFragment) ->
    #headers{
       priority=Priority,
       block_fragment=BlockFragment
      }.

-spec read_binary(binary(),
                  frame_header()) ->
                         {ok, payload(), binary()}
                       | {error, stream_id(), error_code(), binary()}.
read_binary(Bin, H = #frame_header{length=L}) ->
    <<PayloadBin:L/binary,Rem/bits>> = Bin,
    case http2_padding:read_possibly_padded_payload(PayloadBin, H) of
        {error, Code} ->
            {error, 0, Code, Rem};
        Data ->
            {Priority, PSID, HeaderFragment} =
                case is_priority(H) of
                    true ->
                        {P, PRem} = http2_frame_priority:read_priority(Data),
                        PStream = http2_frame_priority:stream_id(P),
                        {P, PStream, PRem};
                    false ->
                        {undefined, undefined, Data}
                end,

            case PSID =:= H#frame_header.stream_id of
                true ->
                    {error, PSID, ?PROTOCOL_ERROR, Rem};
                false ->

                    Payload = #headers{
                                 priority=Priority,
                                 block_fragment=HeaderFragment
                                },
                    {ok, Payload, Rem}
            end
    end.

is_priority(#frame_header{flags=F}) when ?IS_FLAG(F, ?FLAG_PRIORITY) ->
    true;
is_priority(_) ->
    false.

-spec to_frames(StreamId      :: stream_id(),
                Headers       :: hpack:headers(),
                EncodeContext :: hpack:context(),
                MaxFrameSize  :: pos_integer(),
                EndStream     :: boolean()) ->
                       {[http2_frame:frame()], hpack:context()}.
to_frames(StreamId, Headers, EncodeContext, MaxFrameSize, EndStream) ->
    {ok, {HeadersBin, NewContext}} = hpack:encode(Headers, EncodeContext),

    %% Break HeadersBin into chunks
    Chunks = split(HeadersBin, MaxFrameSize),

    Frames = build_frames(StreamId, Chunks, EndStream),

    {Frames, NewContext}.

-spec to_binary(payload()) -> iodata().
to_binary(#headers{
             priority=P,
             block_fragment=BF
            }) ->
    case P of
        undefined ->
            BF;
        _ ->
            [http2_frame_priority:to_binary(P), BF]
    end.

-spec from_frames([http2_frame:frame()], binary()) -> binary().
from_frames([{#frame_header{type=?HEADERS},#headers{block_fragment=BF}}|Continuations])->
    from_frames(Continuations, BF);
from_frames([{#frame_header{type=?PUSH_PROMISE},PP}|Continuations])->
    BF = http2_frame_push_promise:block_fragment(PP),
    from_frames(Continuations, BF).

from_frames([], Acc) ->
    Acc;
from_frames([{#frame_header{type=?CONTINUATION},Cont}|Continuations], Acc) ->
    BF = http2_frame_continuation:block_fragment(Cont),
    from_frames(Continuations, <<Acc/binary,BF/binary>>).

-spec split(Binary::binary(),
            MaxFrameSize::pos_integer()) ->
                   [binary()].
split(Binary, MaxFrameSize) ->
    split(Binary, MaxFrameSize, []).

-spec split(Binary::binary(),
            MaxFrameSize::pos_integer(),
            [binary()]) ->
                   [binary()].
split(Binary, MaxFrameSize, Acc)
  when byte_size(Binary) =< MaxFrameSize ->
    lists:reverse([Binary|Acc]);
split(Binary, MaxFrameSize, Acc) ->
    <<NextFrame:MaxFrameSize/binary,Remaining/binary>> = Binary,
    split(Remaining, MaxFrameSize, [NextFrame|Acc]).

%% Now build frames.
%% The first will be a HEADERS frame, followed by CONTINUATION
%% If EndStream, that flag needs to be set on the first frame
%% ?FLAG_END_HEADERS needs to be set on the last.
%% If there's only one, it needs to be set on both.
-spec build_frames(StreamId :: stream_id(),
                   Chunks::[binary()],
                   EndStream::boolean()) ->
                          [http2_frame:frame()].
build_frames(StreamId, [FirstChunk|Rest], EndStream) ->
    Flag = case EndStream of
               true ->
                   ?FLAG_END_STREAM;
               false ->
                   0
           end,
    HeadersFrame =
        { #frame_header{
             type=?HEADERS,
             flags=Flag,
             length=byte_size(FirstChunk),
             stream_id=StreamId},
          #headers{
             block_fragment=FirstChunk}},
    [{LastFrameHeader, LastFrameBody}|Frames] =
        build_frames_(StreamId, Rest, [HeadersFrame]),
    NewLastFrame = {
      LastFrameHeader#frame_header{
        flags=LastFrameHeader#frame_header.flags bor ?FLAG_END_HEADERS
       },
      LastFrameBody},

    lists:reverse([NewLastFrame|Frames]).

-spec build_frames_(StreamId::stream_id(),
                    Chunks::[binary()],
                    Acc::[http2_frame:frame()])->
                           [http2_frame:frame()].
build_frames_(_StreamId, [], Acc) ->
    Acc;
build_frames_(StreamId, [NextChunk|Rest], Acc) ->
    NextFrame = {
      #frame_header{
         stream_id=StreamId,
         type=?CONTINUATION,
         flags=0,
         length=byte_size(NextChunk)
        },
      http2_frame_continuation:new(NextChunk)
     },
    build_frames_(StreamId, Rest, [NextFrame|Acc]).
