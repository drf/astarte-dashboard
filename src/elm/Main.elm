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


module Main exposing (main)

import Assets
import Bootstrap.Grid as Grid
import Bootstrap.Navbar as Navbar
import Bootstrap.Utilities.Flex as Flex
import Bootstrap.Utilities.Spacing as Spacing
import Browser exposing (UrlRequest(..))
import Browser.Navigation
import Html exposing (Html, a, div, hr, i, img, li, p, small, span, text, ul)
import Html.Attributes exposing (class, classList, href, src, style)
import Http
import Json.Decode as Decode exposing (Value, at, string)
import Json.Encode as Encode
import Page.Home as Home
import Page.InterfaceBuilder as InterfaceBuilder
import Page.Interfaces as Interfaces
import Page.Login as Login
import Page.RealmSettings as RealmSettings
import Page.TriggerBuilder as TriggerBuilder
import Page.Triggers as Triggers
import Ports
import Route exposing (RealmRoute, Route)
import Task
import Time exposing (Posix)
import Types.Config as Config exposing (Config)
import Types.ExternalMessage exposing (ExternalMsg(..))
import Types.FlashMessage as FlashMessage exposing (FlashMessage, Severity)
import Types.Session as Session exposing (LoginStatus(..), LoginType(..), Session)
import Url exposing (Url)
import Url.Builder


main : Program Value Model Msg
main =
    Browser.application
        { init = init
        , onUrlChange = NewUrl
        , onUrlRequest = UrlRequest
        , view = view
        , update = update
        , subscriptions = subscriptions
        }



-- MODEL


type alias Model =
    { navigationKey : Browser.Navigation.Key
    , selectedPage : Page
    , flashMessages : List FlashMessage
    , messageCounter : Int
    , session : Session
    , navbarState : Navbar.State
    , config : Config
    }


init : Value -> Url -> Browser.Navigation.Key -> ( Model, Cmd Msg )
init jsParam location key =
    let
        hostUrl =
            { location
                | path = "/"
                , query = Nothing
                , fragment = Nothing
            }
                |> Url.toString

        ( navbarState, navbarCmd ) =
            Navbar.initialState NavbarMsg

        configFromJavascript =
            Decode.decodeValue (at [ "config" ] Config.decoder) jsParam
                |> Result.toMaybe
                |> Maybe.withDefault Config.empty

        previousSession =
            Decode.decodeValue (at [ "previousSession" ] string) jsParam
                |> Result.toMaybe
                |> Maybe.andThen (Decode.decodeString Session.decoder >> Result.toMaybe)

        initialSession =
            case previousSession of
                Nothing ->
                    initNewSession hostUrl configFromJavascript

                Just prevSession ->
                    { prevSession | hostUrl = hostUrl }

        ( initialPage, initialCommand, updatedSession ) =
            Route.fromUrl location
                |> processRoute configFromJavascript initialSession

        initialModel =
            { navigationKey = key
            , selectedPage = initialPage
            , flashMessages = []
            , messageCounter = 0
            , session = updatedSession
            , navbarState = navbarState
            , config = configFromJavascript
            }
    in
    ( initialModel
    , Cmd.batch
        [ navbarCmd
        , initialCommand
        ]
    )


initNewSession : String -> Config -> Session
initNewSession hostUrl config =
    let
        apiConfig =
            { realmManagementUrl = config.realmManagementApiUrl
            , realm = ""
            , token = ""
            }
    in
    { hostUrl = hostUrl
    , loginStatus = NotLoggedIn
    , apiConfig = apiConfig
    }


type Page
    = Public PublicPage
    | Realm String RealmPage


type PublicPage
    = LoginPage Login.Model


type RealmPage
    = HomePage Home.Model
    | InterfacesPage Interfaces.Model
    | InterfaceBuilderPage InterfaceBuilder.Model
    | TriggersPage Triggers.Model
    | TriggerBuilderPage TriggerBuilder.Model
    | RealmSettingsPage RealmSettings.Model



-- UPDATE


type Msg
    = NavbarMsg Navbar.State
    | NewUrl Url
    | UrlRequest UrlRequest
    | UpdateSession (Maybe Session)
    | LoginMsg Login.Msg
    | HomeMsg Home.Msg
    | InterfacesMsg Interfaces.Msg
    | InterfaceBuilderMsg InterfaceBuilder.Msg
    | RealmSettingsMsg RealmSettings.Msg
    | TriggersMsg Triggers.Msg
    | TriggerBuilderMsg TriggerBuilder.Msg
    | NewFlashMessage Severity String (List String) Posix
    | ClearOldFlashMessages Posix


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NavbarMsg state ->
            ( { model | navbarState = state }
            , Cmd.none
            )

        NewUrl url ->
            setRoute model <| Route.fromUrl url

        UrlRequest requestUrl ->
            case requestUrl of
                Internal internalUrl ->
                    ( model
                    , Browser.Navigation.pushUrl model.navigationKey <| Url.toString internalUrl
                    )

                External externalUrl ->
                    ( model
                    , Browser.Navigation.load externalUrl
                    )

        UpdateSession Nothing ->
            let
                newSession =
                    initNewSession model.session.hostUrl model.config
            in
            ( { model | session = newSession }
            , Cmd.none
            )

        UpdateSession (Just session) ->
            ( { model | session = session }
            , Cmd.none
            )

        NewFlashMessage severity message details createdAt ->
            let
                displayTime =
                    case severity of
                        FlashMessage.Notice ->
                            3 * 1000

                        FlashMessage.Warning ->
                            6 * 1000

                        FlashMessage.Error ->
                            10 * 1000

                        FlashMessage.Fatal ->
                            24 * 60 * 60 * 1000

                dismissAt =
                    createdAt
                        |> Time.posixToMillis
                        |> (+) displayTime
                        |> Time.millisToPosix

                newFlashMessage =
                    FlashMessage.new model.messageCounter message details severity dismissAt
            in
            ( { model
                | flashMessages = newFlashMessage :: model.flashMessages
                , messageCounter = model.messageCounter + 1
              }
            , Cmd.none
            )

        ClearOldFlashMessages now ->
            let
                filteredMessages =
                    List.filter
                        (\m -> Time.posixToMillis m.dismissAt > Time.posixToMillis now)
                        model.flashMessages
            in
            ( { model | flashMessages = filteredMessages }
            , Cmd.none
            )

        -- Page specific messages
        _ ->
            updatePage model.selectedPage msg model


updatePage : Page -> Msg -> Model -> ( Model, Cmd Msg )
updatePage page msg model =
    case page of
        Public publicPage ->
            updatePublicPage publicPage msg model

        Realm realm realmPage ->
            updateRealmPage realm realmPage msg model


updatePublicPage : PublicPage -> Msg -> Model -> ( Model, Cmd Msg )
updatePublicPage publicPage msg model =
    case ( msg, publicPage ) of
        ( LoginMsg subMsg, LoginPage subModel ) ->
            let
                ( newModel, pageCommand, externalMsg ) =
                    Login.update model.session subMsg subModel

                updatedPageModel =
                    { model | selectedPage = Public <| LoginPage newModel }

                ( updatedModel, newCommands ) =
                    handleExternalMessage updatedPageModel externalMsg
            in
            ( updatedModel
            , Cmd.batch
                [ newCommands
                , Cmd.map LoginMsg pageCommand
                ]
            )

        -- Ignore messages from not matching pages
        ( _, _ ) ->
            ( model
            , Cmd.none
            )


updateRealmPage : String -> RealmPage -> Msg -> Model -> ( Model, Cmd Msg )
updateRealmPage realm realmPage msg model =
    let
        ( page, command, externalMsg ) =
            case ( msg, realmPage ) of
                ( InterfacesMsg subMsg, InterfacesPage subModel ) ->
                    updateRealmPageHelper realm (Interfaces.update model.session subMsg subModel) InterfacesMsg InterfacesPage

                ( InterfaceBuilderMsg subMsg, InterfaceBuilderPage subModel ) ->
                    updateRealmPageHelper realm (InterfaceBuilder.update model.session subMsg subModel) InterfaceBuilderMsg InterfaceBuilderPage

                ( RealmSettingsMsg subMsg, RealmSettingsPage subModel ) ->
                    updateRealmPageHelper realm (RealmSettings.update model.session subMsg subModel) RealmSettingsMsg RealmSettingsPage

                ( TriggersMsg subMsg, TriggersPage subModel ) ->
                    updateRealmPageHelper realm (Triggers.update model.session subMsg subModel) TriggersMsg TriggersPage

                ( TriggerBuilderMsg subMsg, TriggerBuilderPage subModel ) ->
                    updateRealmPageHelper realm (TriggerBuilder.update model.session subMsg subModel) TriggerBuilderMsg TriggerBuilderPage

                -- Ignore messages from not matching pages
                ( _, _ ) ->
                    ( model.selectedPage, Cmd.none, Noop )

        updatedPageModel =
            { model | selectedPage = page }

        ( updatedModel, newCommands ) =
            handleExternalMessage updatedPageModel externalMsg
    in
    ( updatedModel
    , Cmd.batch [ newCommands, command ]
    )


updateRealmPageHelper : String -> ( a, Cmd b, ExternalMsg ) -> (b -> Msg) -> (a -> RealmPage) -> ( Page, Cmd Msg, ExternalMsg )
updateRealmPageHelper realm ( newSubModel, pageCommand, msg ) subMsgTagger pageTagger =
    ( Realm realm (pageTagger newSubModel)
    , Cmd.map subMsgTagger pageCommand
    , msg
    )


handleExternalMessage : Model -> ExternalMsg -> ( Model, Cmd Msg )
handleExternalMessage model externalMsg =
    case externalMsg of
        Noop ->
            ( model
            , Cmd.none
            )

        RequestRoute route ->
            setRoute model ( Just route, Nothing )

        RequestRouteWithToken route fragment ->
            setRoute model ( Just route, Just fragment )

        AddFlashMessage severity message details ->
            ( model
            , Task.perform (NewFlashMessage severity message details) Time.now
            )

        DismissFlashMessage messageId ->
            ( { model | flashMessages = List.filter (\message -> message.id /= messageId) model.flashMessages }
            , Cmd.none
            )

        Batch messages ->
            List.foldl handleBatchedMessages ( model, Cmd.none ) messages


handleBatchedMessages : ExternalMsg -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
handleBatchedMessages message ( model, cmd ) =
    let
        ( updatedModel, newCommands ) =
            handleExternalMessage model message
    in
    ( updatedModel
    , Cmd.batch [ cmd, newCommands ]
    )


pageInit : RealmRoute -> Config -> Session -> ( Page, Cmd Msg, Session )
pageInit realmRoute config session =
    case realmRoute of
        Route.Auth _ _ ->
            -- already logged in
            initHomePage session session.apiConfig.realm

        Route.Home ->
            initHomePage session session.apiConfig.realm

        Route.Logout ->
            let
                ( page, command, updatedSession ) =
                    initLoginPage config session

                logoutPath =
                    case session.loginStatus of
                        LoggedIn (OAuthLogin authUrl) ->
                            Url.Builder.custom
                                (Url.Builder.CrossOrigin authUrl)
                                [ "logout" ]
                                [ Url.Builder.string "redirect_uri" session.hostUrl ]
                                Nothing

                        _ ->
                            Route.toString <| Route.RealmSelection (Just "token")
            in
            ( page
            , Cmd.batch
                [ Ports.storeSession Nothing
                , Browser.Navigation.load <| logoutPath
                ]
            , updatedSession
            )

        Route.RealmSettings ->
            initSettingsPage session session.apiConfig.realm

        Route.ListInterfaces ->
            initInterfacesPage session session.apiConfig.realm

        Route.NewInterface ->
            initInterfaceBuilderPage Nothing session session.apiConfig.realm

        Route.ShowInterface name major ->
            initInterfaceBuilderPage (Just ( name, major )) session session.apiConfig.realm

        Route.ListTriggers ->
            initTriggersPage session session.apiConfig.realm

        Route.NewTrigger ->
            initTriggerBuilderPage Nothing session session.apiConfig.realm

        Route.ShowTrigger name ->
            initTriggerBuilderPage (Just name) session session.apiConfig.realm


initLoginPage : Config -> Session -> ( Page, Cmd Msg, Session )
initLoginPage config session =
    let
        authType =
            case session.loginStatus of
                RequestLogin loginType ->
                    loginType

                _ ->
                    config.defaultAuth

        ( initialSubModel, initialPageCommand ) =
            Login.init config authType
    in
    ( Public (LoginPage initialSubModel)
    , Cmd.map LoginMsg initialPageCommand
    , session
    )


initHomePage : Session -> String -> ( Page, Cmd Msg, Session )
initHomePage session realm =
    let
        ( initialModel, initialCommand ) =
            Home.init session
    in
    ( Realm realm (HomePage initialModel)
    , Cmd.map HomeMsg initialCommand
    , session
    )


initInterfacesPage : Session -> String -> ( Page, Cmd Msg, Session )
initInterfacesPage session realm =
    let
        ( initialModel, initialCommand ) =
            Interfaces.init session
    in
    ( Realm realm (InterfacesPage initialModel)
    , Cmd.map InterfacesMsg initialCommand
    , session
    )


initInterfaceBuilderPage : Maybe ( String, Int ) -> Session -> String -> ( Page, Cmd Msg, Session )
initInterfaceBuilderPage maybeInterfaceId session realm =
    let
        ( initialModel, initialCommand ) =
            InterfaceBuilder.init maybeInterfaceId session
    in
    ( Realm realm (InterfaceBuilderPage initialModel)
    , Cmd.map InterfaceBuilderMsg initialCommand
    , session
    )


initTriggersPage : Session -> String -> ( Page, Cmd Msg, Session )
initTriggersPage session realm =
    let
        ( initialModel, initialCommand ) =
            Triggers.init session
    in
    ( Realm realm (TriggersPage initialModel)
    , Cmd.map TriggersMsg initialCommand
    , session
    )


initTriggerBuilderPage : Maybe String -> Session -> String -> ( Page, Cmd Msg, Session )
initTriggerBuilderPage maybeTriggerName session realm =
    let
        ( initialModel, initialCommand ) =
            TriggerBuilder.init maybeTriggerName session
    in
    ( Realm realm (TriggerBuilderPage initialModel)
    , Cmd.map TriggerBuilderMsg initialCommand
    , session
    )


initSettingsPage : Session -> String -> ( Page, Cmd Msg, Session )
initSettingsPage session realm =
    let
        ( initialModel, initialCommand ) =
            RealmSettings.init session
    in
    ( Realm realm (RealmSettingsPage initialModel)
    , Cmd.map RealmSettingsMsg initialCommand
    , session
    )



-- ROUTE PROCESSING


setRoute : Model -> ( Maybe Route, Maybe String ) -> ( Model, Cmd Msg )
setRoute model ( maybeRoute, maybeToken ) =
    let
        ( page, command, updatedSession ) =
            processRoute model.config model.session ( maybeRoute, maybeToken )
    in
    ( { model
        | selectedPage = page
        , session = updatedSession
      }
    , command
    )


processRoute : Config -> Session -> ( Maybe Route, Maybe String ) -> ( Page, Cmd Msg, Session )
processRoute config session ( maybeRoute, maybeToken ) =
    let
        loggedIn =
            Session.isLoggedIn session
    in
    case maybeRoute of
        Nothing ->
            if loggedIn then
                processRealmRoute maybeToken Route.Home config session

            else
                initLoginPage config session

        Just Route.Root ->
            if loggedIn then
                processRealmRoute maybeToken Route.Home config session

            else
                initLoginPage config session

        Just (Route.RealmSelection loginTypeString) ->
            if loggedIn then
                processRealmRoute maybeToken Route.ListInterfaces config session

            else
                let
                    loginStatus =
                        case loginTypeString of
                            Just "token" ->
                                RequestLogin Config.Token

                            _ ->
                                RequestLogin Config.OAuth

                    updatedSession =
                        { session | loginStatus = loginStatus }
                in
                initLoginPage config updatedSession

        Just (Route.Realm realmRoute) ->
            processRealmRoute maybeToken realmRoute config session


processRealmRoute : Maybe String -> RealmRoute -> Config -> Session -> ( Page, Cmd Msg, Session )
processRealmRoute maybeToken realmRoute config session =
    let
        apiConfig =
            session.apiConfig
    in
    if String.isEmpty apiConfig.realm then
        case realmRoute of
            Route.Auth maybeRealm maybeOauthUrl ->
                attemptLogin maybeRealm maybeToken maybeOauthUrl config session

            _ ->
                -- not authorized
                initLoginPage config session

    else
        case maybeToken of
            Just token ->
                -- update token
                let
                    sessionWithUpdatedToken =
                        session
                            |> Session.setToken token

                    ( page, command, updatedSession ) =
                        pageInit realmRoute config sessionWithUpdatedToken
                in
                ( page
                , Cmd.batch [ storeSession updatedSession, command ]
                , updatedSession
                )

            Nothing ->
                -- access granted
                pageInit realmRoute config session


attemptLogin : Maybe String -> Maybe String -> Maybe String -> Config -> Session -> ( Page, Cmd Msg, Session )
attemptLogin maybeRealm maybeToken maybeOauthUrl config session =
    let
        apiConfig =
            session.apiConfig
    in
    case ( maybeRealm, maybeToken ) of
        ( Just realm, Just token ) ->
            -- login into realm
            let
                updatedApiConfig =
                    { apiConfig
                        | realm = realm
                        , token = token
                    }

                loginType =
                    case maybeOauthUrl of
                        Nothing ->
                            Session.TokenLogin

                        Just url ->
                            Session.OAuthLogin url

                sessionWithCredentials =
                    { session
                        | loginStatus = LoggedIn loginType
                        , apiConfig = updatedApiConfig
                    }

                ( page, command, updatedSession ) =
                    pageInit Route.Home config sessionWithCredentials
            in
            ( page
            , Cmd.batch [ storeSession updatedSession, command ]
            , updatedSession
            )

        _ ->
            -- missing parameters
            initLoginPage config session



-- VIEW


view : Model -> Browser.Document Msg
view model =
    { title = "Astarte - Dashboard"
    , body =
        [ renderNavbar model
        , div
            [ class "main-content"
            , Spacing.p3
            ]
            [ renderPage model model.selectedPage ]
        ]
    }


renderNavbar : Model -> Html Msg
renderNavbar model =
    case model.selectedPage of
        Public (LoginPage _) ->
            text ""

        Realm realmName _ ->
            Navbar.config NavbarMsg
                |> Navbar.withAnimation
                |> Navbar.attrs
                    [ classList
                        [ ( "navbar-vertical", True )
                        , ( "fixed-left", True )
                        ]
                    ]
                |> Navbar.collapseMedium
                |> Navbar.brand
                    [ href <| Route.toString (Route.Realm Route.Home) ]
                    [ img
                        [ src <| Assets.path Assets.dashboardIcon
                        , style "height" "3em"
                        , Spacing.mr3
                        ]
                        []
                    , div
                        [ class "realm-brand" ]
                        [ p [ Spacing.mb0 ] [ text realmName ]
                        , small [ class "font-weight-light" ] [ text "dashboard" ]
                        ]
                    ]
                |> Navbar.customItems
                    [ navbarLinks model.selectedPage ]
                |> Navbar.view model.navbarState



{-
   as for elm-bootstrap 4.1.0, vertical navbars are not supported.
   This is the implementation using bootstrap css classes
-}


navbarLinks : Page -> Navbar.CustomItem Msg
navbarLinks selectedPage =
    Navbar.customItem <|
        Grid.container
            [ Flex.col ]
            [ hr [] []
            , ul
                [ class "navbar-nav" ]
                [ li [ class "navbar-item" ]
                    [ a
                        [ classList
                            [ ( "nav-link", True )
                            , ( "active", isHomeRelated selectedPage )
                            ]
                        , href <| Route.toString (Route.Realm Route.Home)
                        ]
                        [ span
                            [ class "icon-spacer" ]
                            [ i [ class "fas", class "fa-home" ] [] ]
                        , text "Home"
                        ]
                    ]
                , li [ class "navbar-item" ]
                    [ a
                        [ classList
                            [ ( "nav-link", True )
                            , ( "active", isInterfacesRelated selectedPage )
                            ]
                        , href <| Route.toString (Route.Realm Route.ListInterfaces)
                        ]
                        [ span
                            [ class "icon-spacer" ]
                            [ i [ class "fas", class "fa-stream" ] [] ]
                        , text "Interfaces"
                        ]
                    ]
                , li [ class "navbar-item" ]
                    [ a
                        [ classList
                            [ ( "nav-link", True )
                            , ( "active", isTriggersRelated selectedPage )
                            ]
                        , href <| Route.toString (Route.Realm Route.ListTriggers)
                        ]
                        [ span
                            [ class "icon-spacer" ]
                            [ i [ class "fas", class "fa-bolt" ] [] ]
                        , text "Triggers"
                        ]
                    ]
                , li [ class "navbar-item" ]
                    [ a
                        [ classList
                            [ ( "nav-link", True )
                            , ( "active", isSettingsRelated selectedPage )
                            ]
                        , href <| Route.toString (Route.Realm Route.RealmSettings)
                        ]
                        [ span
                            [ class "icon-spacer" ]
                            [ i [ class "fas", class "fa-cog" ] [] ]
                        , text "Settings"
                        ]
                    ]
                , li [ class "navbar-item" ]
                    [ hr [] [] ]
                , li [ class "navbar-item" ]
                    [ a
                        [ class "nav-link"
                        , href <| Route.toString (Route.Realm Route.Logout)
                        ]
                        [ span
                            [ class "icon-spacer" ]
                            [ i [ class "fas", class "fa-sign-out-alt" ] [] ]
                        , text "Logout"
                        ]
                    ]
                ]
            ]


isHomeRelated : Page -> Bool
isHomeRelated page =
    case page of
        Realm _ (HomePage _) ->
            True

        _ ->
            False


isInterfacesRelated : Page -> Bool
isInterfacesRelated page =
    case page of
        Realm _ (InterfacesPage _) ->
            True

        Realm _ (InterfaceBuilderPage _) ->
            True

        _ ->
            False


isTriggersRelated : Page -> Bool
isTriggersRelated page =
    case page of
        Realm _ (TriggersPage _) ->
            True

        Realm _ (TriggerBuilderPage _) ->
            True

        _ ->
            False


isSettingsRelated : Page -> Bool
isSettingsRelated page =
    case page of
        Realm _ (RealmSettingsPage _) ->
            True

        _ ->
            False


renderPage : Model -> Page -> Html Msg
renderPage model page =
    case page of
        Public publicPage ->
            renderPublicPage model.flashMessages publicPage

        Realm realm realmPage ->
            renderProtectedPage model.flashMessages realm realmPage


renderPublicPage : List FlashMessage -> PublicPage -> Html Msg
renderPublicPage flashMessages page =
    case page of
        LoginPage submodel ->
            Login.view submodel flashMessages
                |> Html.map LoginMsg


renderProtectedPage : List FlashMessage -> String -> RealmPage -> Html Msg
renderProtectedPage flashMessages realm page =
    case page of
        HomePage submodel ->
            Home.view submodel flashMessages
                |> Html.map HomeMsg

        InterfacesPage submodel ->
            Interfaces.view submodel flashMessages
                |> Html.map InterfacesMsg

        InterfaceBuilderPage submodel ->
            InterfaceBuilder.view submodel flashMessages
                |> Html.map InterfaceBuilderMsg

        TriggersPage submodel ->
            Triggers.view submodel flashMessages
                |> Html.map TriggersMsg

        RealmSettingsPage submodel ->
            RealmSettings.view submodel flashMessages
                |> Html.map RealmSettingsMsg

        TriggerBuilderPage submodel ->
            TriggerBuilder.view submodel flashMessages
                |> Html.map TriggerBuilderMsg



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    if List.isEmpty model.flashMessages then
        Sub.batch
            [ Navbar.subscriptions model.navbarState NavbarMsg
            , Sub.map UpdateSession sessionChange
            , pageSubscriptions model.selectedPage
            ]

    else
        Sub.batch
            [ Navbar.subscriptions model.navbarState NavbarMsg
            , Time.every 1000 ClearOldFlashMessages
            , Sub.map UpdateSession sessionChange
            , pageSubscriptions model.selectedPage
            ]


pageSubscriptions : Page -> Sub Msg
pageSubscriptions page =
    case page of
        Realm _ (InterfaceBuilderPage submodel) ->
            Sub.map InterfaceBuilderMsg <| InterfaceBuilder.subscriptions submodel

        Realm _ (InterfacesPage submodel) ->
            Sub.map InterfacesMsg <| Interfaces.subscriptions submodel

        Realm _ (TriggerBuilderPage submodel) ->
            Sub.map TriggerBuilderMsg <| TriggerBuilder.subscriptions submodel

        Realm _ (TriggersPage submodel) ->
            Sub.map TriggersMsg <| Triggers.subscriptions submodel

        Realm _ (RealmSettingsPage submodel) ->
            Sub.map RealmSettingsMsg <| RealmSettings.subscriptions submodel

        _ ->
            Sub.none


sessionChange : Sub (Maybe Session)
sessionChange =
    Ports.onSessionChange (Decode.decodeValue Session.decoder >> Result.toMaybe)


storeSession : Session -> Cmd msg
storeSession session =
    Session.encode session
        |> Encode.encode 0
        |> Just
        |> Ports.storeSession
