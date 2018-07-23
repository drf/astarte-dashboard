module Page.Interfaces exposing (Model, Msg, init, update, view, subscriptions)

import Dict exposing (Dict)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onClick, onInput)
import Navigation
import Json.Decode as Decode


-- Types

import AstarteApi exposing (..)
import Route
import Types.Session exposing (Session)
import Types.ExternalMessage as ExternalMsg exposing (ExternalMsg)
import Types.Interface exposing (Interface)
import Types.FlashMessage as FlashMessage exposing (FlashMessage, Severity)
import Types.FlashMessageHelpers as FlashMessageHelpers


-- bootstrap components

import Bootstrap.Accordion as Accordion
import Bootstrap.Button as Button
import Bootstrap.ButtonGroup as ButtonGroup exposing (LinkButtonItem)
import Bootstrap.Card as Card
import Bootstrap.Card.Block as Block
import Bootstrap.Form as Form
import Bootstrap.Grid as Grid
import Bootstrap.Grid.Col as Col
import Bootstrap.Grid.Row as Row
import Bootstrap.ListGroup as ListGroup
import Bootstrap.Utilities.Size as Size
import Bootstrap.Utilities.Display as Display
import Bootstrap.Utilities.Spacing as Spacing


type alias Model =
    { interfaces : Dict String (List Int)
    , accordionState : Accordion.State
    }


init : Session -> ( Model, Cmd Msg )
init session =
    ( { interfaces = Dict.empty
      , accordionState = Accordion.initialState
      }
    , AstarteApi.listInterfaces session
        GetInterfaceListDone
        (ShowError "Cannot retrieve interfaces.")
        RedirectToLogin
    )


type Msg
    = GetInterfaceList
    | GetInterfaceListDone (List String)
    | GetInterfaceMajors String
    | GetInterfaceMajorsDone String (List Int)
    | OpenInterfaceBuilder
    | ShowInterface String Int
    | Forward ExternalMsg
    | ShowError String String
    | RedirectToLogin
      -- accordion
    | AccordionMsg Accordion.State


update : Session -> Msg -> Model -> ( Model, Cmd Msg, ExternalMsg )
update session msg model =
    case msg of
        GetInterfaceList ->
            ( model
            , AstarteApi.listInterfaces session
                GetInterfaceListDone
                (ShowError "Cannot retrieve interfaces.")
                RedirectToLogin
            , ExternalMsg.Noop
            )

        GetInterfaceListDone interfaces ->
            ( { model
                | interfaces =
                    interfaces
                        |> List.map (\x -> ( x, [] ))
                        |> Dict.fromList
              }
            , interfaces
                |> List.map (\name -> getInterfaceMajorsHelper name session)
                |> Cmd.batch
            , ExternalMsg.Noop
            )

        GetInterfaceMajors interfaceName ->
            ( model
            , getInterfaceMajorsHelper interfaceName session
            , ExternalMsg.Noop
            )

        GetInterfaceMajorsDone interfaceName majors ->
            ( { model
                | interfaces =
                    Dict.update
                        interfaceName
                        (\_ -> Just <| List.reverse majors)
                        model.interfaces
              }
            , Cmd.none
            , ExternalMsg.Noop
            )

        OpenInterfaceBuilder ->
            ( model
            , Navigation.modifyUrl <| Route.toString (Route.Realm Route.NewInterface)
            , ExternalMsg.Noop
            )

        ShowInterface name major ->
            ( model
            , Navigation.modifyUrl <| Route.toString (Route.Realm <| Route.ShowInterface name major)
            , ExternalMsg.Noop
            )

        ShowError actionError errorMessage ->
            ( model
            , Cmd.none
            , [ actionError, " ", errorMessage ]
                |> String.concat
                |> ExternalMsg.AddFlashMessage FlashMessage.Error
            )

        RedirectToLogin ->
            ( model
            , Navigation.modifyUrl <| Route.toString (Route.Realm Route.Logout)
            , ExternalMsg.Noop
            )

        Forward msg ->
            ( model
            , Cmd.none
            , msg
            )

        AccordionMsg state ->
            ( { model | accordionState = state }
            , Cmd.none
            , ExternalMsg.Noop
            )


getInterfaceMajorsHelper : String -> Session -> Cmd Msg
getInterfaceMajorsHelper interfaceName session =
    AstarteApi.listInterfaceMajors interfaceName
        session
        (GetInterfaceMajorsDone interfaceName)
        (ShowError <| String.concat [ "Cannot retrieve major versions for ", interfaceName, " interface." ])
        RedirectToLogin


view : Model -> List FlashMessage -> Html Msg
view model flashMessages =
    Grid.container
        [ Spacing.mt5Sm ]
        [ Grid.row
            [ Row.middleSm
            , Row.topSm
            ]
            [ Grid.col
                [ Col.sm12 ]
                [ FlashMessageHelpers.renderFlashMessages flashMessages Forward ]
            ]
        , Grid.row
            [ Row.attrs [ Spacing.mt2 ] ]
            [ Grid.col
                [ Col.sm12 ]
                [ h5 [ Display.inline ]
                    [ if Dict.isEmpty model.interfaces then
                        text "No interfaces installed"
                      else
                        text "Interfaces"
                    ]
                , Button.button
                    [ Button.primary
                    , Button.onClick OpenInterfaceBuilder
                    , Button.attrs [ class "float-right" ]
                    ]
                    [ text "Install a New Interface ..." ]
                , Button.button
                    [ Button.primary
                    , Button.onClick GetInterfaceList
                    , Button.attrs [ class "float-right", Spacing.mr1 ]
                    ]
                    [ text "Reload" ]
                ]
            ]
        , Grid.row []
            [ Grid.col
                [ Col.sm12 ]
                [ Accordion.config AccordionMsg
                    |> Accordion.withAnimation
                    |> Accordion.cards
                        (model.interfaces
                            |> Dict.toList
                            |> List.map renderInterfaceCard
                        )
                    |> Accordion.view model.accordionState
                ]
            ]
        ]


renderInterfaceCard : ( String, List Int ) -> Accordion.Card Msg
renderInterfaceCard ( interfaceName, majors ) =
    Accordion.card
        { id = interfaceNameToHtmlId interfaceName
        , options = [ Card.attrs [ Spacing.mt2 ] ]
        , header =
            Accordion.headerH4
                [ onClick <| GetInterfaceMajors interfaceName ]
                (Accordion.toggle []
                    [ text interfaceName ]
                )
        , blocks =
            [ Accordion.listGroup
                (if List.isEmpty majors then
                    [ ListGroup.li [] [ text "Loading..." ] ]
                 else
                    List.map (renderMajor interfaceName) majors
                )
            ]
        }


interfaceNameToHtmlId : String -> String
interfaceNameToHtmlId name =
    name
        |> String.map
            (\c ->
                if c == '.' then
                    '-'
                else
                    c
            )
        |> String.append "m"


renderMajor : String -> Int -> ListGroup.Item Msg
renderMajor interfaceName major =
    ListGroup.li []
        [ a
            [ href "#"
            , Html.Events.onWithOptions
                "click"
                { stopPropagation = True
                , preventDefault = True
                }
                (Decode.succeed <| ShowInterface interfaceName major)
            ]
            [ text <| interfaceName ++ " v" ++ (toString major) ]
        ]



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Accordion.subscriptions model.accordionState AccordionMsg
