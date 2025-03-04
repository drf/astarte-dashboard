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


module Page.InterfaceBuilder exposing (Model, Msg, init, subscriptions, update, view)

import AstarteApi
import Bootstrap.Accordion as Accordion
import Bootstrap.Button as Button
import Bootstrap.Card as Card
import Bootstrap.Card.Block as Block
import Bootstrap.Form as Form
import Bootstrap.Form.Checkbox as Checkbox
import Bootstrap.Form.Fieldset as Fieldset
import Bootstrap.Form.Input as Input
import Bootstrap.Form.InputGroup as InputGroup
import Bootstrap.Form.Radio as Radio
import Bootstrap.Form.Select as Select
import Bootstrap.Form.Textarea as Textarea
import Bootstrap.Grid as Grid
import Bootstrap.Grid.Col as Col
import Bootstrap.Grid.Row as Row
import Bootstrap.Modal as Modal
import Bootstrap.Utilities.Border as Border
import Bootstrap.Utilities.Display as Display
import Bootstrap.Utilities.Size as Size
import Bootstrap.Utilities.Spacing as Spacing
import Debouncer.Basic as Debouncer exposing (Debouncer, fromSeconds, toDebouncer)
import Dict exposing (Dict)
import Html exposing (Html, b, br, h5, i, p, small, text)
import Html.Attributes exposing (class, for, selected, value)
import Html.Events exposing (onSubmit)
import Modal.MappingBuilder as MappingBuilder
import Route
import Spinner
import Task
import Time exposing (Posix)
import Types.ExternalMessage as ExternalMsg exposing (ExternalMsg)
import Types.FlashMessage as FlashMessage exposing (FlashMessage, Severity)
import Types.FlashMessageHelpers as FlashMessageHelpers
import Types.Interface as Interface exposing (Interface)
import Types.InterfaceMapping as InterfaceMapping
    exposing
        ( InterfaceMapping
        , mappingTypeToEnglishString
        , reliabilityToEnglishString
        , retentionToEnglishString
        )
import Types.Session exposing (Session)
import Types.SuggestionPopup as SuggestionPopup exposing (SuggestionPopup)


type alias Model =
    { interface : Interface
    , interfaceEditMode : Bool
    , minMinor : Int
    , deleteModalVisibility : Modal.Visibility
    , confirmModalVisibility : Modal.Visibility
    , confirmInterfaceName : String
    , showSource : Bool
    , sourceBuffer : String
    , sourceBufferStatus : BufferStatus
    , sourceDebouncer : Debouncer Msg Msg
    , accordionState : Accordion.State
    , spinner : Spinner.Model
    , showSpinner : Bool
    , interfaceNameSuggestionPopup : SuggestionPopup

    -- common mappings settings
    , objectReliability : InterfaceMapping.Reliability
    , objectRetention : InterfaceMapping.Retention
    , objectExpiry : Int
    , objectExplicitTimestamp : Bool

    -- mapping builder
    , mappingBuilderModel : MappingBuilder.Model
    }


type BufferStatus
    = Valid
    | Invalid
    | Typing


init : Maybe ( String, Int ) -> Session -> ( Model, Cmd Msg )
init maybeInterfaceId session =
    let
        debouncer =
            Debouncer.manual
                |> Debouncer.settleWhenQuietFor (Just (fromSeconds 1))
                |> toDebouncer

        ( showSpinner, initialCommand ) =
            case maybeInterfaceId of
                Just ( name, major ) ->
                    ( True
                    , AstarteApi.getInterface session.apiConfig
                        name
                        major
                        GetInterfaceDone
                        (ShowError "Could not retrieve selected interface")
                        RedirectToLogin
                    )

                Nothing ->
                    ( False
                    , Cmd.none
                    )

        interfaceNameSuggestionPopup =
            SuggestionPopup.new "Interface name should be prefixed with a reverse domain name, and should use PascalCase (e.g. com.example.MyInterface)."
    in
    ( { interface = Interface.empty
      , interfaceEditMode = False
      , minMinor = 0
      , objectReliability = InterfaceMapping.Unreliable
      , objectRetention = InterfaceMapping.Discard
      , objectExpiry = 0
      , objectExplicitTimestamp = False
      , deleteModalVisibility = Modal.hidden
      , confirmModalVisibility = Modal.hidden
      , confirmInterfaceName = ""
      , showSource = True
      , sourceBuffer = Interface.toPrettySource Interface.empty
      , sourceBufferStatus = Valid
      , sourceDebouncer = debouncer
      , accordionState = Accordion.initialState
      , spinner = Spinner.init
      , showSpinner = showSpinner
      , interfaceNameSuggestionPopup = interfaceNameSuggestionPopup
      , mappingBuilderModel = MappingBuilder.empty
      }
    , initialCommand
    )


type InterfaceNameStatus
    = InvalidInterfaceName
    | ImproveableInterfaceName
    | GoodInterfaceName


type ModalResult
    = ModalCancel
    | ModalOk


type Msg
    = GetInterfaceDone Interface
    | AddInterfaceDone
    | DeleteInterfaceDone
    | UpdateInterfaceDone
    | RemoveMapping InterfaceMapping
    | ShowDeleteModal
    | CloseDeleteModal ModalResult
    | ShowConfirmModal
    | CloseConfirmModal ModalResult
    | ShowError String AstarteApi.Error
    | RedirectToLogin
    | ToggleSource
    | InterfaceSourceChanged
    | UpdateSource String
    | SourceDebounceMsg (Debouncer.Msg Msg)
    | Forward ExternalMsg
      -- interface messages
    | UpdateInterfaceName String
    | UpdateInterfaceMajor String
    | UpdateInterfaceMinor String
    | UpdateInterfaceType Interface.InterfaceType
    | UpdateInterfaceAggregation Interface.AggregationType
    | UpdateInterfaceOwnership Interface.Owner
    | UpdateInterfaceHasMeta Bool
    | UpdateInterfaceDescription String
    | UpdateInterfaceDoc String
      -- common mapping messages
    | UpdateObjectMappingReliability String
    | UpdateObjectMappingRetention String
    | UpdateObjectMappingExpiry String
    | UpdateObjectMappingExplicitTimestamp Bool
      -- modal
    | UpdateConfirmInterfaceName String
    | MappingBuilderMsg MappingBuilder.Msg
    | ShowAddMappingModal
    | ShowEditMappingModal InterfaceMapping
      -- accordion
    | AccordionMsg Accordion.State
      -- spinner
    | SpinnerMsg Spinner.Msg
      -- SuggestionPopup
    | SuggestionPopupMsg SuggestionPopup.Msg


update : Session -> Msg -> Model -> ( Model, Cmd Msg, ExternalMsg )
update session msg model =
    case msg of
        GetInterfaceDone interface ->
            let
                mappingEditMode =
                    False

                isObject =
                    interface.aggregation == Interface.Object

                shown =
                    False

                newMappingBuilderModel =
                    MappingBuilder.init
                        InterfaceMapping.empty
                        mappingEditMode
                        (interface.iType == Interface.Properties)
                        isObject
                        shown

                commonObjectParams =
                    case ( isObject, List.head <| Interface.mappingsAsList interface ) of
                        ( True, Just mapping ) ->
                            { reliability = mapping.reliability
                            , retention = mapping.retention
                            , expiry = mapping.expiry
                            , explicitTimestamp = mapping.explicitTimestamp
                            }

                        _ ->
                            { reliability = InterfaceMapping.Unreliable
                            , retention = InterfaceMapping.Discard
                            , expiry = 0
                            , explicitTimestamp = False
                            }
            in
            ( { model
                | interface = interface
                , interfaceEditMode = True
                , minMinor = interface.minor
                , sourceBuffer = Interface.toPrettySource interface
                , mappingBuilderModel = newMappingBuilderModel
                , objectReliability = commonObjectParams.reliability
                , objectRetention = commonObjectParams.retention
                , objectExpiry = commonObjectParams.expiry
                , objectExplicitTimestamp = commonObjectParams.explicitTimestamp
                , showSpinner = False
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        AddInterfaceDone ->
            ( model
            , Cmd.none
            , ExternalMsg.Batch
                [ ExternalMsg.AddFlashMessage FlashMessage.Notice "Interface succesfully installed." []
                , ExternalMsg.RequestRoute <| Route.Realm Route.ListInterfaces
                ]
            )

        UpdateInterfaceDone ->
            ( { model
                | minMinor = model.interface.minor
                , interface = Interface.sealMappings model.interface
              }
            , Cmd.none
            , ExternalMsg.AddFlashMessage FlashMessage.Notice "Changes succesfully applied." []
            )

        DeleteInterfaceDone ->
            ( model
            , Cmd.none
            , ExternalMsg.Batch
                [ ExternalMsg.AddFlashMessage FlashMessage.Notice "Interface succesfully deleted." []
                , ExternalMsg.RequestRoute <| Route.Realm Route.ListInterfaces
                ]
            )

        ShowDeleteModal ->
            ( { model
                | deleteModalVisibility = Modal.shown
                , confirmInterfaceName = ""
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        CloseDeleteModal modalResult ->
            case modalResult of
                ModalOk ->
                    if model.interface.name == model.confirmInterfaceName then
                        ( { model | deleteModalVisibility = Modal.hidden }
                        , AstarteApi.deleteInterface session.apiConfig
                            model.interface.name
                            model.interface.major
                            DeleteInterfaceDone
                            (ShowError "Could not delete interface")
                            RedirectToLogin
                        , ExternalMsg.Noop
                        )

                    else
                        ( model
                        , Cmd.none
                        , ExternalMsg.Noop
                        )

                ModalCancel ->
                    ( { model | deleteModalVisibility = Modal.hidden }
                    , Cmd.none
                    , ExternalMsg.Noop
                    )

        ShowConfirmModal ->
            ( { model | confirmModalVisibility = Modal.shown }
            , Cmd.none
            , ExternalMsg.Noop
            )

        CloseConfirmModal modalResult ->
            case modalResult of
                ModalOk ->
                    let
                        command =
                            if model.interfaceEditMode then
                                AstarteApi.updateInterface session.apiConfig
                                    model.interface
                                    UpdateInterfaceDone
                                    (ShowError "Could not apply changes")
                                    RedirectToLogin

                            else
                                AstarteApi.addNewInterface session.apiConfig
                                    model.interface
                                    AddInterfaceDone
                                    (ShowError "Could not install interface")
                                    RedirectToLogin
                    in
                    ( { model | confirmModalVisibility = Modal.hidden }
                    , command
                    , ExternalMsg.Noop
                    )

                ModalCancel ->
                    ( { model | confirmModalVisibility = Modal.hidden }
                    , Cmd.none
                    , ExternalMsg.Noop
                    )

        ShowError actionError apiError ->
            let
                ( apiErrorTitle, apiErrorDetails ) =
                    AstarteApi.errorToHumanReadable apiError

                flashmessageTitle =
                    String.concat [ actionError, ": ", apiErrorTitle ]
            in
            ( { model | showSpinner = False }
            , Cmd.none
            , ExternalMsg.AddFlashMessage FlashMessage.Error flashmessageTitle apiErrorDetails
            )

        RedirectToLogin ->
            -- TODO: We should save page context, ask for login and then restore previous context
            ( model
            , Cmd.none
            , ExternalMsg.RequestRoute <| Route.Realm Route.Logout
            )

        ToggleSource ->
            ( { model | showSource = not model.showSource }
            , Cmd.none
            , ExternalMsg.Noop
            )

        InterfaceSourceChanged ->
            case Interface.fromString model.sourceBuffer of
                Ok interface ->
                    if not model.interfaceEditMode || Interface.compareId model.interface interface then
                        let
                            commonObjectParams =
                                case ( interface.aggregation, List.head <| Interface.mappingsAsList interface ) of
                                    ( Interface.Object, Just mapping ) ->
                                        { reliability = mapping.reliability
                                        , retention = mapping.retention
                                        , expiry = mapping.expiry
                                        , explicitTimestamp = mapping.explicitTimestamp
                                        }

                                    _ ->
                                        { reliability = InterfaceMapping.Unreliable
                                        , retention = InterfaceMapping.Discard
                                        , expiry = 0
                                        , explicitTimestamp = False
                                        }
                        in
                        ( { model
                            | sourceBuffer = Interface.toPrettySource interface
                            , sourceBufferStatus = Valid
                            , interface = interface
                            , objectReliability = commonObjectParams.reliability
                            , objectRetention = commonObjectParams.retention
                            , objectExpiry = commonObjectParams.expiry
                            , objectExplicitTimestamp = commonObjectParams.explicitTimestamp
                          }
                        , Cmd.none
                        , ExternalMsg.Noop
                        )

                    else
                        ( { model | sourceBufferStatus = Invalid }
                        , Cmd.none
                        , ExternalMsg.AddFlashMessage
                            FlashMessage.Error
                            "Interface name and major do not match"
                            []
                        )

                Err _ ->
                    ( { model | sourceBufferStatus = Invalid }
                    , Cmd.none
                    , ExternalMsg.Noop
                    )

        UpdateSource newSource ->
            ( { model
                | sourceBuffer = newSource
                , sourceBufferStatus = Typing
              }
            , Task.perform
                (\_ ->
                    InterfaceSourceChanged
                        |> Debouncer.provideInput
                        |> SourceDebounceMsg
                )
                (Task.succeed ())
            , ExternalMsg.Noop
            )

        SourceDebounceMsg subMsg ->
            let
                ( subModel, subCmd, emittedMsg ) =
                    Debouncer.update subMsg model.sourceDebouncer

                mappedCmd =
                    Cmd.map SourceDebounceMsg subCmd

                updatedModel =
                    { model | sourceDebouncer = subModel }
            in
            case emittedMsg of
                Just emitted ->
                    let
                        ( newModel, updateCommand, externalCommand ) =
                            update session emitted updatedModel
                    in
                    ( newModel
                    , Cmd.batch [ updateCommand, mappedCmd ]
                    , externalCommand
                    )

                Nothing ->
                    ( updatedModel
                    , mappedCmd
                    , ExternalMsg.Noop
                    )

        Forward externalMsg ->
            ( model
            , Cmd.none
            , externalMsg
            )

        UpdateInterfaceName newName ->
            let
                newInterface =
                    Interface.setName newName model.interface
            in
            ( { model
                | interface = newInterface
                , sourceBuffer = Interface.toPrettySource newInterface
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        UpdateInterfaceMajor newMajor ->
            case String.toInt newMajor of
                Just major ->
                    if major > 0 || (major == 0 && model.interface.minor > 0) then
                        let
                            newInterface =
                                Interface.setMajor major model.interface
                        in
                        ( { model
                            | interface = newInterface
                            , sourceBuffer = Interface.toPrettySource newInterface
                          }
                        , Cmd.none
                        , ExternalMsg.Noop
                        )

                    else
                        ( model
                        , Cmd.none
                        , ExternalMsg.Noop
                        )

                Nothing ->
                    ( model
                    , Cmd.none
                    , ExternalMsg.Noop
                    )

        UpdateInterfaceMinor newMinor ->
            case String.toInt newMinor of
                Just minor ->
                    if minor >= model.minMinor && not (model.interface.major == 0 && minor == 0) then
                        let
                            newInterface =
                                Interface.setMinor minor model.interface
                        in
                        ( { model
                            | interface = newInterface
                            , sourceBuffer = Interface.toPrettySource newInterface
                          }
                        , Cmd.none
                        , ExternalMsg.Noop
                        )

                    else
                        ( model
                        , Cmd.none
                        , ExternalMsg.Noop
                        )

                Nothing ->
                    ( model
                    , Cmd.none
                    , ExternalMsg.Noop
                    )

        UpdateInterfaceType newInterfaceType ->
            let
                newInterface =
                    if newInterfaceType == Interface.Properties then
                        model.interface
                            |> Interface.setType Interface.Properties
                            |> Interface.setAggregation Interface.Individual

                    else
                        Interface.setType Interface.Datastream model.interface
            in
            ( { model
                | interface = newInterface
                , sourceBuffer = Interface.toPrettySource newInterface
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        UpdateInterfaceAggregation newAggregation ->
            let
                newInterface =
                    if newAggregation == Interface.Object then
                        model.interface
                            |> Interface.setAggregation Interface.Object
                            |> Interface.setOwnership Interface.Device

                    else
                        Interface.setAggregation Interface.Individual model.interface
            in
            ( { model
                | interface = newInterface
                , sourceBuffer = Interface.toPrettySource newInterface
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        UpdateInterfaceOwnership newOwner ->
            let
                newInterface =
                    Interface.setOwnership newOwner model.interface
            in
            ( { model
                | interface = newInterface
                , sourceBuffer = Interface.toPrettySource newInterface
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        UpdateInterfaceHasMeta hasMeta ->
            let
                newInterface =
                    Interface.setHasMeta hasMeta model.interface
            in
            ( { model
                | interface = newInterface
                , sourceBuffer = Interface.toPrettySource newInterface
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        UpdateInterfaceDescription newDescription ->
            let
                newInterface =
                    Interface.setDescription newDescription model.interface
            in
            ( { model
                | interface = newInterface
                , sourceBuffer = Interface.toPrettySource newInterface
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        UpdateInterfaceDoc newDoc ->
            let
                newInterface =
                    Interface.setDoc newDoc model.interface
            in
            ( { model
                | interface = newInterface
                , sourceBuffer = Interface.toPrettySource newInterface
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        RemoveMapping mapping ->
            let
                newInterface =
                    Interface.removeMapping mapping model.interface
            in
            ( { model
                | interface = newInterface
                , sourceBuffer = Interface.toPrettySource newInterface
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        UpdateObjectMappingReliability newReliability ->
            case InterfaceMapping.stringToReliability newReliability of
                Ok reliability ->
                    let
                        newInterface =
                            model.interface
                                |> Interface.setObjectMappingAttributes
                                    reliability
                                    model.objectRetention
                                    model.objectExpiry
                                    model.objectExplicitTimestamp
                    in
                    ( { model
                        | objectReliability = reliability
                        , interface = newInterface
                        , sourceBuffer = Interface.toPrettySource newInterface
                      }
                    , Cmd.none
                    , ExternalMsg.Noop
                    )

                Err err ->
                    ( model
                    , Cmd.none
                    , ExternalMsg.Noop
                    )

        UpdateObjectMappingRetention newMapRetention ->
            case InterfaceMapping.stringToRetention newMapRetention of
                Ok retention ->
                    let
                        expiry =
                            if retention == InterfaceMapping.Discard then
                                0

                            else
                                model.objectExpiry

                        newInterface =
                            model.interface
                                |> Interface.setObjectMappingAttributes
                                    model.objectReliability
                                    retention
                                    expiry
                                    model.objectExplicitTimestamp
                    in
                    ( { model
                        | objectRetention = retention
                        , objectExpiry = expiry
                        , interface = newInterface
                        , sourceBuffer = Interface.toPrettySource newInterface
                      }
                    , Cmd.none
                    , ExternalMsg.Noop
                    )

                Err err ->
                    ( model
                    , Cmd.none
                    , ExternalMsg.Noop
                    )

        UpdateObjectMappingExpiry newExpiry ->
            case String.toInt newExpiry of
                Just expiry ->
                    if expiry >= 0 then
                        let
                            newInterface =
                                model.interface
                                    |> Interface.setObjectMappingAttributes
                                        model.objectReliability
                                        model.objectRetention
                                        expiry
                                        model.objectExplicitTimestamp
                        in
                        ( { model
                            | objectExpiry = expiry
                            , interface = newInterface
                            , sourceBuffer = Interface.toPrettySource newInterface
                          }
                        , Cmd.none
                        , ExternalMsg.Noop
                        )

                    else
                        ( model
                        , Cmd.none
                        , ExternalMsg.Noop
                        )

                Nothing ->
                    ( model
                    , Cmd.none
                    , ExternalMsg.Noop
                    )

        UpdateObjectMappingExplicitTimestamp explicitTimestamp ->
            let
                newInterface =
                    model.interface
                        |> Interface.setObjectMappingAttributes
                            model.objectReliability
                            model.objectRetention
                            model.objectExpiry
                            explicitTimestamp
            in
            ( { model
                | objectExplicitTimestamp = explicitTimestamp
                , interface = newInterface
                , sourceBuffer = Interface.toPrettySource newInterface
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        UpdateConfirmInterfaceName userInput ->
            ( { model | confirmInterfaceName = userInput }
            , Cmd.none
            , ExternalMsg.Noop
            )

        MappingBuilderMsg mappingBuilderMsg ->
            ( handleMappingBuilderMessages mappingBuilderMsg model
            , Cmd.none
            , ExternalMsg.Noop
            )

        ShowAddMappingModal ->
            let
                mappingEditMode =
                    False

                shown =
                    True

                newMappingBuilderModel =
                    MappingBuilder.init
                        InterfaceMapping.empty
                        mappingEditMode
                        (model.interface.iType == Interface.Properties)
                        (model.interface.aggregation == Interface.Object)
                        shown
            in
            ( { model | mappingBuilderModel = newMappingBuilderModel }
            , Cmd.none
            , ExternalMsg.Noop
            )

        ShowEditMappingModal mapping ->
            let
                mappingEditMode =
                    True

                shown =
                    True

                newMappingBuilderModel =
                    MappingBuilder.init
                        mapping
                        mappingEditMode
                        (model.interface.iType == Interface.Properties)
                        (model.interface.aggregation == Interface.Object)
                        shown
            in
            ( { model | mappingBuilderModel = newMappingBuilderModel }
            , Cmd.none
            , ExternalMsg.Noop
            )

        AccordionMsg state ->
            ( { model | accordionState = state }
            , Cmd.none
            , ExternalMsg.Noop
            )

        SpinnerMsg spinnerMsg ->
            ( { model | spinner = Spinner.update spinnerMsg model.spinner }
            , Cmd.none
            , ExternalMsg.Noop
            )

        SuggestionPopupMsg popupMsg ->
            ( { model
                | interfaceNameSuggestionPopup =
                    SuggestionPopup.update model.interfaceNameSuggestionPopup popupMsg
              }
            , Cmd.none
            , ExternalMsg.Noop
            )


handleMappingBuilderMessages : MappingBuilder.Msg -> Model -> Model
handleMappingBuilderMessages message model =
    let
        ( updatedBuilderModel, externalMessage ) =
            MappingBuilder.update message model.mappingBuilderModel
    in
    case externalMessage of
        MappingBuilder.Noop ->
            { model | mappingBuilderModel = updatedBuilderModel }

        MappingBuilder.AddNewMapping mapping ->
            let
                updatedMapping =
                    if
                        (model.interface.aggregation == Interface.Object)
                            && (model.interface.iType == Interface.Datastream)
                    then
                        mapping
                            |> InterfaceMapping.setRetention model.objectRetention
                            |> InterfaceMapping.setReliability model.objectReliability
                            |> InterfaceMapping.setExpiry model.objectExpiry
                            |> InterfaceMapping.setExplicitTimestamp model.objectExplicitTimestamp

                    else
                        mapping

                newInterface =
                    Interface.addMapping updatedMapping model.interface
            in
            { model
                | interface = newInterface
                , sourceBuffer = Interface.toPrettySource newInterface
                , mappingBuilderModel = updatedBuilderModel
            }

        MappingBuilder.EditMapping mapping ->
            let
                newInterface =
                    Interface.editMapping mapping model.interface
            in
            { model
                | interface = newInterface
                , sourceBuffer = Interface.toPrettySource newInterface
                , mappingBuilderModel = updatedBuilderModel
            }


view : Model -> List FlashMessage -> Html Msg
view model flashMessages =
    Grid.containerFluid
        [ class "bg-white"
        , Border.rounded
        , Spacing.pb3
        ]
        [ Grid.row
            [ Row.attrs [ Spacing.mt2 ] ]
            [ Grid.col
                [ Col.sm12 ]
                [ FlashMessageHelpers.renderFlashMessages flashMessages Forward ]
            ]
        , Grid.row
            [ Row.attrs [ Spacing.mt2 ] ]
            [ Grid.col
                [ if model.showSource then
                    Col.sm6

                  else
                    Col.sm12
                ]
                [ renderContent
                    model
                    model.interface
                    model.interfaceEditMode
                    model.accordionState
                ]
            , Grid.col
                [ if model.showSource then
                    Col.sm6

                  else
                    Col.attrs [ Display.none ]
                ]
                [ renderInterfaceSource model.interface model.sourceBuffer model.sourceBufferStatus ]
            ]
        , Grid.row []
            [ Grid.col
                [ Col.sm12 ]
                [ renderDeleteInterfaceModal model
                , renderConfirmModal model
                , Html.map MappingBuilderMsg <| MappingBuilder.view model.mappingBuilderModel
                ]
            ]
        , if model.showSpinner then
            Spinner.view Spinner.defaultConfig model.spinner

          else
            text ""
        ]


renderContent : Model -> Interface -> Bool -> Accordion.State -> Html Msg
renderContent model interface interfaceEditMode accordionState =
    Grid.containerFluid []
        [ Form.form []
            [ Form.row []
                [ Form.col [ Col.sm11 ]
                    [ h5
                        [ Display.inline
                        , class "align-middle"
                        , class "font-weight-normal"
                        , class "text-truncate"
                        ]
                        [ text
                            (if interfaceEditMode then
                                interface.name

                             else
                                "Install a new interface"
                            )
                        , if interfaceEditMode && interface.major == 0 then
                            Button.button
                                [ Button.warning
                                , Button.attrs [ Spacing.ml2, class "text-secondary" ]
                                , Button.onClick ShowDeleteModal
                                ]
                                [ i [ class "fas", class "fa-times", Spacing.mr2 ] []
                                , text "Delete..."
                                ]

                          else
                            text ""
                        ]
                    ]
                , Form.col [ Col.sm1 ]
                    [ Button.button
                        [ Button.secondary
                        , Button.attrs [ class "float-right" ]
                        , Button.onClick ToggleSource
                        ]
                        [ i [ class "fas", class "fa-arrows-alt-h" ] [] ]
                    ]
                ]
            , Form.row []
                [ Form.col [ Col.sm6 ]
                    [ renderInterfaceNameInput interface.name interfaceEditMode model.interfaceNameSuggestionPopup ]
                , Form.col [ Col.sm3 ]
                    [ Form.group []
                        [ Form.label [ for "interfaceMajor" ] [ text "Major" ]
                        , Input.number
                            [ Input.id "interfaceMajor"
                            , Input.readonly interfaceEditMode
                            , Input.value <| String.fromInt interface.major
                            , Input.onInput UpdateInterfaceMajor
                            ]
                        ]
                    ]
                , Form.col [ Col.sm3 ]
                    [ Form.group []
                        [ Form.label [ for "interfaceMinor" ] [ text "Minor" ]
                        , Input.number
                            [ Input.id "interfaceMinor"
                            , Input.value <| String.fromInt interface.minor
                            , Input.onInput UpdateInterfaceMinor
                            ]
                        ]
                    ]
                ]
            , Form.row []
                [ Form.col [ Col.sm4 ]
                    [ Form.group []
                        [ Form.label [ for "interfaceType" ] [ text "Type" ]
                        , Fieldset.config
                            |> Fieldset.asGroup
                            |> Fieldset.children
                                (Radio.radioList "interfaceType"
                                    [ Radio.create
                                        [ Radio.id "itrb1"
                                        , Radio.disabled interfaceEditMode
                                        , Radio.checked <| interface.iType == Interface.Datastream
                                        , Radio.onClick <| UpdateInterfaceType Interface.Datastream
                                        ]
                                        "Datastream"
                                    , Radio.create
                                        [ Radio.id "itrb2"
                                        , Radio.disabled interfaceEditMode
                                        , Radio.checked <| interface.iType == Interface.Properties
                                        , Radio.onClick <| UpdateInterfaceType Interface.Properties
                                        ]
                                        "Properties"
                                    ]
                                )
                            |> Fieldset.view
                        ]
                    ]
                , Form.col [ Col.sm4 ]
                    [ Form.group []
                        [ Form.label [ for "interfaceAggregation" ] [ text "Aggregation" ]
                        , Fieldset.config
                            |> Fieldset.asGroup
                            |> Fieldset.children
                                (Radio.radioList "interfaceAggregation"
                                    [ Radio.create
                                        [ Radio.id "iarb1"
                                        , Radio.disabled <| interfaceEditMode || interface.iType == Interface.Properties
                                        , Radio.checked <| interface.aggregation == Interface.Individual
                                        , Radio.onClick <| UpdateInterfaceAggregation Interface.Individual
                                        ]
                                        "Individual"
                                    , Radio.create
                                        [ Radio.id "iarb2"
                                        , Radio.disabled <| interfaceEditMode || interface.iType == Interface.Properties
                                        , Radio.checked <| interface.aggregation == Interface.Object
                                        , Radio.onClick <| UpdateInterfaceAggregation Interface.Object
                                        ]
                                        "Object"
                                    ]
                                )
                            |> Fieldset.view
                        ]
                    ]
                , Form.col [ Col.sm4 ]
                    [ Form.group []
                        [ Form.label [ for "interfaceOwnership" ] [ text "Ownership" ]
                        , Fieldset.config
                            |> Fieldset.asGroup
                            |> Fieldset.children
                                (Radio.radioList "interfaceOwnership"
                                    [ Radio.create
                                        [ Radio.id "iorb1"
                                        , Radio.disabled <| interfaceEditMode || interface.aggregation == Interface.Object
                                        , Radio.checked <| interface.ownership == Interface.Device
                                        , Radio.onClick <| UpdateInterfaceOwnership Interface.Device
                                        ]
                                        "Device"
                                    , Radio.create
                                        [ Radio.id "iorb2"
                                        , Radio.disabled <| interfaceEditMode || interface.aggregation == Interface.Object
                                        , Radio.checked <| interface.ownership == Interface.Server
                                        , Radio.onClick <| UpdateInterfaceOwnership Interface.Server
                                        ]
                                        "Server"
                                    ]
                                )
                            |> Fieldset.view
                        ]
                    ]
                ]
            , renderCommonMappingSettings model
            , Form.row []
                [ Form.col [ Col.sm12 ]
                    [ Form.group []
                        [ Form.label [ for "interfaceDescription" ] [ text "Description" ]
                        , Textarea.textarea
                            [ Textarea.id "interfaceDescription"
                            , Textarea.rows 3
                            , Textarea.value interface.description
                            , Textarea.onInput UpdateInterfaceDescription
                            ]
                        ]
                    ]
                ]
            , Form.row []
                [ Form.col [ Col.sm12 ]
                    [ Form.group []
                        [ Form.label [ for "interfaceDoc" ] [ text "Documentation" ]
                        , Textarea.textarea
                            [ Textarea.id "interfaceDoc"
                            , Textarea.rows 3
                            , Textarea.value interface.doc
                            , Textarea.onInput UpdateInterfaceDoc
                            ]
                        ]
                    ]
                ]
            , Form.row []
                [ Form.col [ Col.sm12 ]
                    [ h5
                        [ Display.inline
                        , class "font-weight-normal"
                        , class "align-middle"
                        ]
                        [ if Dict.isEmpty interface.mappings then
                            text "No mappings added"

                          else
                            text "Mappings"
                        ]
                    , Button.button
                        [ Button.outlinePrimary
                        , Button.attrs [ class "float-right", Spacing.ml2 ]
                        , Button.onClick ShowAddMappingModal
                        ]
                        [ i [ class "fas", class "fa-plus", Spacing.mr2 ] []
                        , text "Add new Mapping ..."
                        ]
                    ]
                ]
            , Form.row []
                [ Form.col [ Col.sm12 ]
                    [ Accordion.config AccordionMsg
                        |> Accordion.withAnimation
                        |> Accordion.cards
                            (interface.mappings
                                |> Dict.values
                                |> List.map renderMapping
                            )
                        |> Accordion.view accordionState
                    ]
                ]
            , Form.row [ Row.rightSm ]
                [ Form.col [ Col.sm4 ]
                    [ renderConfirmButton interfaceEditMode ]
                ]
            ]
        ]


renderInterfaceNameInput : String -> Bool -> SuggestionPopup -> Html Msg
renderInterfaceNameInput interfaceName editMode interfaceNameSuggestionPopup =
    let
        interfaceNameStatus =
            case ( Interface.isValidInterfaceName interfaceName, Interface.isGoodInterfaceName interfaceName ) of
                ( True, True ) ->
                    GoodInterfaceName

                ( True, False ) ->
                    ImproveableInterfaceName

                ( False, _ ) ->
                    InvalidInterfaceName
    in
    Form.group []
        (if editMode then
            [ Form.label [ for "interfaceName" ] [ text "Name" ]
            , Input.text
                [ Input.id "interfaceName"
                , Input.readonly True
                , Input.value interfaceName
                ]
            ]

         else
            [ Form.label [ for "interfaceName" ] [ text "Name" ]
            , Input.text
                [ Input.id "interfaceName"
                , Input.readonly False
                , Input.value interfaceName
                , Input.onInput UpdateInterfaceName
                , Input.success |> when (interfaceNameStatus == GoodInterfaceName)
                , Input.danger |> when (interfaceNameStatus == InvalidInterfaceName)
                ]
            , Html.map SuggestionPopupMsg
                (SuggestionPopup.view interfaceNameSuggestionPopup <| interfaceNameStatus == ImproveableInterfaceName)
            ]
        )


renderCommonMappingSettings : Model -> Html Msg
renderCommonMappingSettings model =
    Form.row
        (if model.interface.aggregation == Interface.Object then
            []

         else
            [ Row.attrs [ Display.none ] ]
        )
        [ Form.col [ Col.sm4 ]
            [ Form.group []
                [ Form.label [ for "objectMappingReliability" ] [ text "Reliability" ]
                , Select.select
                    [ Select.id "objectMappingReliability"
                    , Select.disabled model.interfaceEditMode
                    , Select.onChange UpdateObjectMappingReliability
                    ]
                    [ Select.item
                        [ value "unreliable"
                        , selected <| model.objectReliability == InterfaceMapping.Unreliable
                        ]
                        [ text "Unreliable" ]
                    , Select.item
                        [ value "guaranteed"
                        , selected <| model.objectReliability == InterfaceMapping.Guaranteed
                        ]
                        [ text "Guaranteed" ]
                    , Select.item
                        [ value "unique"
                        , selected <| model.objectReliability == InterfaceMapping.Unique
                        ]
                        [ text "Unique" ]
                    ]
                ]
            ]
        , Form.col
            [ if model.objectRetention == InterfaceMapping.Discard then
                Col.sm8

              else
                Col.sm4
            ]
            [ Form.group []
                [ Form.label [ for "objectMappingRetention" ] [ text "Retention" ]
                , Select.select
                    [ Select.id "objectMappingRetention"
                    , Select.disabled model.interfaceEditMode
                    , Select.onChange UpdateObjectMappingRetention
                    ]
                    [ Select.item
                        [ value "discard"
                        , selected <| model.objectRetention == InterfaceMapping.Discard
                        ]
                        [ text "Discard" ]
                    , Select.item
                        [ value "volatile"
                        , selected <| model.objectRetention == InterfaceMapping.Volatile
                        ]
                        [ text "Volatile" ]
                    , Select.item
                        [ value "stored"
                        , selected <| model.objectRetention == InterfaceMapping.Stored
                        ]
                        [ text "Stored" ]
                    ]
                ]
            ]
        , Form.col
            [ if model.objectRetention == InterfaceMapping.Discard then
                Col.attrs [ Display.none ]

              else
                Col.sm4
            ]
            [ Form.group []
                [ Form.label [ for "objectMappingExpiry" ] [ text "Expiry" ]
                , InputGroup.number
                    [ Input.id "objectMappingExpiry"
                    , Input.disabled model.interfaceEditMode
                    , Input.value <| String.fromInt model.objectExpiry
                    , Input.onInput UpdateObjectMappingExpiry
                    ]
                    |> InputGroup.config
                    |> InputGroup.successors
                        [ InputGroup.span [] [ text "ms" ] ]
                    |> InputGroup.view
                ]
            ]
        , Form.col [ Col.sm6 ]
            [ Form.group []
                [ Checkbox.checkbox
                    [ Checkbox.id "objectMappingExpTimestamp"
                    , Checkbox.disabled model.interfaceEditMode
                    , Checkbox.checked model.objectExplicitTimestamp
                    , Checkbox.onCheck UpdateObjectMappingExplicitTimestamp
                    ]
                    "Explicit timestamp"
                ]
            ]
        ]


renderConfirmButton : Bool -> Html Msg
renderConfirmButton editMode =
    Button.button
        [ Button.primary
        , Button.attrs [ class "float-right", Spacing.ml2 ]
        , Button.onClick ShowConfirmModal
        ]
        [ if editMode then
            text "Apply Changes"

          else
            text "Install Interface"
        ]


renderInterfaceSource : Interface -> String -> BufferStatus -> Html Msg
renderInterfaceSource interface sourceBuffer status =
    Textarea.textarea
        [ Textarea.id "interfaceSource"
        , Textarea.rows 30
        , Textarea.value sourceBuffer
        , case status of
            Valid ->
                Textarea.success

            Invalid ->
                Textarea.danger

            Typing ->
                Textarea.attrs []
        , Textarea.onInput UpdateSource
        , Textarea.attrs [ class "text-monospace", Size.h100 ]
        ]


renderMapping : InterfaceMapping -> Accordion.Card Msg
renderMapping mapping =
    Accordion.card
        { id = endpointToHtmlId mapping.endpoint
        , options = [ Card.attrs [ Spacing.mb2 ] ]
        , header = renderMappingHeader mapping
        , blocks =
            [ ( textBlock "Description" mapping.description
              , String.isEmpty mapping.description
              )
            , ( textBlock "Reliability" <| reliabilityToEnglishString mapping.reliability
              , mapping.reliability == InterfaceMapping.Unreliable
              )
            , ( textBlock "Retention" <| retentionToEnglishString mapping.retention
              , mapping.retention == InterfaceMapping.Discard
              )
            , ( textBlock "Expiry" <| String.fromInt mapping.expiry
              , mapping.retention == InterfaceMapping.Discard || mapping.expiry == 0
              )
            , ( textBlock "Explicit timestamp" <| boolToString mapping.explicitTimestamp
              , not mapping.explicitTimestamp
              )
            , ( textBlock "Allow unset" <| boolToString mapping.allowUnset
              , not mapping.allowUnset
              )
            , ( textBlock "Doc" mapping.doc
              , String.isEmpty mapping.doc
              )
            ]
                |> List.filterMap
                    (\( block, default ) ->
                        if default then
                            Nothing

                        else
                            Just block
                    )
        }


textBlock : String -> String -> Accordion.CardBlock Msg
textBlock title content =
    Accordion.block []
        [ Block.titleH5
            [ Display.inline
            , Spacing.mr2
            ]
            [ text title ]
        , Block.text
            [ Display.inline ]
            [ text content ]
        ]


endpointToHtmlId : String -> String
endpointToHtmlId endpoint =
    endpoint
        |> String.map
            (\c ->
                if c == '/' then
                    '-'

                else
                    c
            )
        |> String.append "m"


renderMappingHeader : InterfaceMapping -> Accordion.Header Msg
renderMappingHeader mapping =
    Accordion.headerH5 [] (Accordion.toggle [] [ text mapping.endpoint ])
        |> Accordion.appendHeader
            (if mapping.draft then
                [ small
                    [ Display.inline, Spacing.p2 ]
                    [ text <| mappingTypeToEnglishString mapping.mType ]
                ]
                    ++ renderMappingControls mapping

             else
                [ small
                    [ Display.inline, Spacing.p2 ]
                    [ text <| mappingTypeToEnglishString mapping.mType ]
                ]
            )


renderMappingControls : InterfaceMapping -> List (Html Msg)
renderMappingControls mapping =
    [ Button.button
        [ Button.outlinePrimary
        , Button.attrs [ class "float-right" ]
        , Button.onClick <| RemoveMapping mapping
        ]
        [ text "Remove" ]
    , Button.button
        [ Button.outlinePrimary
        , Button.attrs [ Spacing.mr2Sm, class "float-right" ]
        , Button.onClick <| ShowEditMappingModal mapping
        ]
        [ text "Edit..." ]
    ]


renderDeleteInterfaceModal : Model -> Html Msg
renderDeleteInterfaceModal model =
    Modal.config (CloseDeleteModal ModalCancel)
        |> Modal.large
        |> Modal.h5 [] [ text "Confirmation Required" ]
        |> Modal.body []
            [ Form.form [ onSubmit (CloseDeleteModal ModalOk) ]
                [ Form.row []
                    [ Form.col [ Col.sm12 ]
                        [ text "You are going to remove "
                        , b [] [ text <| model.interface.name ++ " v0. " ]
                        , text "This might cause data loss, removed interfaces cannot be restored. Are you sure?"
                        ]
                    ]
                , Form.row []
                    [ Form.col [ Col.sm12 ]
                        [ text "Please type "
                        , b [] [ text model.interface.name ]
                        , text " to proceed."
                        ]
                    ]
                , Form.row []
                    [ Form.col [ Col.sm12 ]
                        [ Input.text
                            [ Input.id "confirmInterfaceName"
                            , Input.placeholder "Interface Name"
                            , Input.value model.confirmInterfaceName
                            , Input.onInput UpdateConfirmInterfaceName
                            ]
                        ]
                    ]
                ]
            ]
        |> Modal.footer []
            [ Button.button
                [ Button.secondary
                , Button.onClick <| CloseDeleteModal ModalCancel
                ]
                [ text "Cancel" ]
            , Button.button
                [ Button.primary
                , Button.disabled <| model.interface.name /= model.confirmInterfaceName
                , Button.onClick <| CloseDeleteModal ModalOk
                ]
                [ text "Confirm" ]
            ]
        |> Modal.view model.deleteModalVisibility


renderConfirmModal : Model -> Html Msg
renderConfirmModal model =
    Modal.config (CloseConfirmModal ModalCancel)
        |> Modal.large
        |> Modal.h5 [] [ text "Confirmation Required" ]
        |> Modal.body []
            [ Grid.container []
                [ Grid.row []
                    [ Grid.col
                        [ Col.sm12 ]
                        (confirmModalWarningText
                            model.interfaceEditMode
                            model.interface.name
                            model.interface.major
                        )
                    ]
                ]
            ]
        |> Modal.footer []
            [ Button.button
                [ Button.secondary
                , Button.onClick <| CloseConfirmModal ModalCancel
                ]
                [ text "Cancel" ]
            , Button.button
                [ Button.primary
                , Button.onClick <| CloseConfirmModal ModalOk
                ]
                [ text "Confirm" ]
            ]
        |> Modal.view model.confirmModalVisibility


confirmModalWarningText : Bool -> String -> Int -> List (Html Msg)
confirmModalWarningText editMode interfaceName interfaceMajor =
    if editMode then
        [ text "Update the interface "
        , b [] [ text interfaceName ]
        , text "?"
        ]

    else
        [ p []
            [ text "You are about to install the interface "
            , b [] [ text interfaceName ]
            , text "."
            ]
        , if interfaceMajor > 0 then
            p [] [ text "Interface major is greater than zero, that means you will not be able to change already installed mappings." ]

          else
            p []
                [ text "As its major version is 0, this is a draft interface, which can be deleted."
                , br [] []
                , text "In such a case, any data sent through this interface will be lost."
                , br [] []
                , text "Draft Interfaces should be used for development and testing purposes only."
                ]
        , text "Are you sure you want to continue?"
        ]


when : Bool -> Input.Option m -> Input.Option m
when condition attribute =
    if condition then
        attribute

    else
        Input.attrs []



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        ([ Accordion.subscriptions model.accordionState AccordionMsg
         , Sub.map SuggestionPopupMsg <| SuggestionPopup.subs model.interfaceNameSuggestionPopup
         ]
            ++ (if model.showSpinner then
                    [ Sub.map SpinnerMsg Spinner.subscription ]

                else
                    []
               )
        )


boolToString : Bool -> String
boolToString b =
    if b then
        "true"

    else
        "false"
