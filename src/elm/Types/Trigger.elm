{-
   This file is part of Astarte.

   Copyright 2018 Ispirata Srl

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-}


module Types.Trigger exposing
    ( SimpleTrigger(..)
    , Template(..)
    , Trigger
    , decoder
    , empty
    , encode
    , fromString
    , setName
    , setSimpleTrigger
    , setTemplate
    , setUrl
    , toPrettySource
    )

import Json.Decode as Decode exposing (Decoder, Value, andThen, decodeString, field, index, map, nullable, string)
import Json.Decode.Pipeline exposing (optionalAt, required, requiredAt, resolve)
import Json.Encode as Encode
import Types.DataTrigger as DataTrigger exposing (DataTrigger)
import Types.DeviceTrigger as DeviceTrigger exposing (DeviceTrigger)


type alias Trigger =
    { name : String

    -- action
    , url : String
    , template : Template

    -- Simple triggers
    , simpleTrigger : SimpleTrigger
    }


empty : Trigger
empty =
    { name = ""
    , url = ""
    , template = NoTemplate
    , simpleTrigger = Data DataTrigger.empty
    }


type Template
    = NoTemplate
    | Mustache String


type SimpleTrigger
    = Data DataTrigger
    | Device DeviceTrigger



-- Setters


setName : String -> Trigger -> Trigger
setName name trigger =
    { trigger | name = name }


setUrl : String -> Trigger -> Trigger
setUrl url trigger =
    { trigger | url = url }


setTemplate : Template -> Trigger -> Trigger
setTemplate template trigger =
    { trigger | template = template }


setSimpleTrigger : SimpleTrigger -> Trigger -> Trigger
setSimpleTrigger simpleTrigger trigger =
    { trigger | simpleTrigger = simpleTrigger }



-- Encoding


encode : Trigger -> Value
encode t =
    Encode.object
        [ ( "name", Encode.string t.name )
        , ( "action"
          , Encode.object
                ([ ( "http_post_url", Encode.string t.url ) ]
                    ++ templateEncoder t.template
                )
          )
        , ( "simple_triggers", Encode.list simpleTriggerEncoder [ t.simpleTrigger ] )
        ]


templateEncoder : Template -> List ( String, Value )
templateEncoder template =
    case template of
        NoTemplate ->
            []

        Mustache mustacheTemplate ->
            [ ( "template_type", Encode.string "mustache" )
            , ( "template", Encode.string mustacheTemplate )
            ]


simpleTriggerEncoder : SimpleTrigger -> Value
simpleTriggerEncoder simpleTrigger =
    case simpleTrigger of
        Data dataTrigger ->
            DataTrigger.encode dataTrigger

        Device deviceTrigger ->
            DeviceTrigger.encode deviceTrigger



-- Decoding


decoder : Decoder Trigger
decoder =
    Decode.succeed buildTrigger
        |> required "name" string
        |> requiredAt [ "action", "http_post_url" ] string
        |> optionalAt [ "action", "template_type" ] (nullable string) Nothing
        |> optionalAt [ "action", "template" ] (nullable string) Nothing
        |> required "simple_triggers" (index 0 simpleTriggerDecoder)
        |> resolve


buildTrigger : String -> String -> Maybe String -> Maybe String -> SimpleTrigger -> Decoder Trigger
buildTrigger name url maybeTemplateType maybeTemplate simpleTrigger =
    case stringsToTemplate maybeTemplateType maybeTemplate of
        Ok template ->
            Decode.succeed <| Trigger name url template simpleTrigger

        Err err ->
            Decode.fail err


stringsToTemplate : Maybe String -> Maybe String -> Result String Template
stringsToTemplate maybeTemplateType maybeTemplate =
    case ( maybeTemplateType, maybeTemplate ) of
        ( Nothing, _ ) ->
            Ok NoTemplate

        ( Just "mustache", Just template ) ->
            Ok <| Mustache template

        ( Just "mustache", Nothing ) ->
            Err "Mustache requires a template"

        ( Just templateType, _ ) ->
            Err <| "Uknown template type: " ++ templateType


simpleTriggerDecoder : Decoder SimpleTrigger
simpleTriggerDecoder =
    field "type" string
        |> andThen
            (\str ->
                case str of
                    "data_trigger" ->
                        map Data DataTrigger.decoder

                    "device_trigger" ->
                        map Device DeviceTrigger.decoder

                    _ ->
                        Decode.fail <| "Uknown trigger type " ++ str
            )



-- JsonHelpers


fromString : String -> Result Decode.Error Trigger
fromString source =
    decodeString decoder source


toPrettySource : Trigger -> String
toPrettySource trigger =
    Encode.encode 4 <| encode trigger
