{-
   Copyright 2020 Docspell Contributors

   SPDX-License-Identifier: GPL-3.0-or-later
-}


module Comp.ItemMerge exposing
    ( Model
    , Msg
    , init
    , initQuery
    , update
    , view
    )

import Api
import Api.Model.BasicResult exposing (BasicResult)
import Api.Model.ItemLight exposing (ItemLight)
import Api.Model.ItemLightList exposing (ItemLightList)
import Comp.MenuBar as MB
import Data.Direction
import Data.Fields
import Data.Flags exposing (Flags)
import Data.Icons as Icons
import Data.ItemQuery exposing (ItemQuery)
import Data.ItemTemplate as IT
import Data.SearchMode exposing (SearchMode)
import Data.UiSettings exposing (UiSettings)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onClick)
import Html5.DragDrop as DD
import Http
import Messages.Comp.ItemMerge exposing (Texts)
import Styles as S
import Util.CustomField
import Util.Item
import Util.List


type alias Model =
    { items : List ItemLight
    , showInfoText : Bool
    , dragDrop : DDModel
    , formState : FormState
    }


init : List ItemLight -> Model
init items =
    { items = items
    , showInfoText = False
    , dragDrop = DD.init
    , formState = FormStateInitial
    }


initQuery : Flags -> SearchMode -> ItemQuery -> ( Model, Cmd Msg )
initQuery flags searchMode query =
    let
        itemQuery =
            { offset = Just 0
            , limit = Just 50
            , withDetails = Just True
            , searchMode = Just (Data.SearchMode.asString searchMode)
            , query = Data.ItemQuery.render query
            }
    in
    ( init [], Api.itemSearch flags itemQuery ItemResp )


type alias Dropped =
    { sourceIdx : Int
    , targetIdx : Int
    }


type alias DDModel =
    DD.Model Int Int


type alias DDMsg =
    DD.Msg Int Int


type FormState
    = FormStateInitial
    | FormStateHttp Http.Error
    | FormStateMergeSuccessful
    | FormStateError String



--- Update


type alias UpdateResult =
    { model : Model
    , cmd : Cmd Msg
    , done : Bool
    }


notDoneResult : ( Model, Cmd Msg ) -> UpdateResult
notDoneResult t =
    { model = Tuple.first t
    , cmd = Tuple.second t
    , done = False
    }


type Msg
    = ItemResp (Result Http.Error ItemLightList)
    | ToggleInfoText
    | DragDrop (DD.Msg Int Int)
    | SubmitMerge
    | CancelMerge
    | MergeResp (Result Http.Error BasicResult)


update : Msg -> Model -> UpdateResult
update msg model =
    case msg of
        ItemResp (Ok list) ->
            notDoneResult ( init (flatten list), Cmd.none )

        ItemResp (Err err) ->
            notDoneResult ( { model | formState = FormStateHttp err }, Cmd.none )

        MergeResp (Ok result) ->
            if result.success then
                { model = { model | formState = FormStateMergeSuccessful }
                , cmd = Cmd.none
                , done = True
                }

            else
                { model = { model | formState = FormStateError result.message }
                , cmd = Cmd.none
                , done = False
                }

        MergeResp (Err err) ->
            { model = { model | formState = FormStateHttp err }
            , cmd = Cmd.none
            , done = False
            }

        ToggleInfoText ->
            notDoneResult
                ( { model | showInfoText = not model.showInfoText }
                , Cmd.none
                )

        DragDrop lmsg ->
            let
                ( m, res ) =
                    DD.update lmsg model.dragDrop

                dropped =
                    Maybe.map (\( idx1, idx2, _ ) -> Dropped idx1 idx2) res

                model_ =
                    { model | dragDrop = m }
            in
            case dropped of
                Just data ->
                    let
                        items =
                            Util.List.changePosition data.sourceIdx data.targetIdx model.items
                    in
                    notDoneResult ( { model_ | items = items }, Cmd.none )

                Nothing ->
                    notDoneResult ( model_, Cmd.none )

        SubmitMerge ->
            notDoneResult ( model, Cmd.none )

        CancelMerge ->
            { model = model
            , cmd = Cmd.none
            , done = True
            }


flatten : ItemLightList -> List ItemLight
flatten list =
    list.groups |> List.concatMap .items



--- View


view : Texts -> UiSettings -> Model -> Html Msg
view texts settings model =
    div [ class "px-2 mb-4" ]
        [ h1 [ class S.header1 ]
            [ text texts.title
            , a
                [ class "ml-2"
                , class S.link
                , href "#"
                , onClick ToggleInfoText
                ]
                [ i [ class "fa fa-info-circle" ] []
                ]
            ]
        , p
            [ class S.infoMessage
            , classList [ ( "hidden", not model.showInfoText ) ]
            ]
            [ text texts.infoText
            ]
        , p
            [ class S.warnMessage
            , class "mt-2"
            ]
            [ text texts.deleteWarn
            ]
        , MB.view <|
            { start =
                [ MB.PrimaryButton
                    { tagger = SubmitMerge
                    , title = texts.submitMergeTitle
                    , icon = Just "fa fa-less-than"
                    , label = texts.submitMerge
                    }
                , MB.SecondaryButton
                    { tagger = CancelMerge
                    , title = texts.cancelMergeTitle
                    , icon = Just "fa fa-times"
                    , label = texts.cancelMerge
                    }
                ]
            , end = []
            , rootClasses = "my-4"
            }
        , renderFormState texts model
        , div [ class "flex-col px-2" ]
            (List.indexedMap (itemCard texts settings model) model.items)
        ]


itemCard : Texts -> UiSettings -> Model -> Int -> ItemLight -> Html Msg
itemCard texts settings model index item =
    let
        previewUrl =
            Api.itemBasePreviewURL item.id

        fieldHidden f =
            Data.UiSettings.fieldHidden settings f

        dirIcon =
            i
                [ class (Data.Direction.iconFromMaybe2 item.direction)
                , class "mr-2 w-4 text-center"
                , classList [ ( "hidden", fieldHidden Data.Fields.Direction ) ]
                , IT.render IT.direction (templateCtx texts) item |> title
                ]
                []

        titlePattern =
            settings.cardTitleTemplate.template

        subtitlePattern =
            settings.cardSubtitleTemplate.template

        dropActive =
            let
                currentDrop =
                    getDropId model

                currentDrag =
                    getDragId model
            in
            currentDrop == Just index && currentDrag /= Just index && currentDrag /= Just (index - 1)
    in
    div
        ([ classList [ ( "pt-12 mx-2", dropActive ) ]
         ]
            ++ droppable DragDrop index
        )
        [ div
            ([ class "flex flex-col sm:flex-row rounded"
             , class "cursor-pointer items-center"
             , classList
                [ ( "border-2 border-blue-500 dark:border-blue-500", index == 0 )
                , ( "bg-blue-100 dark:bg-lightblue-900", index == 0 )
                , ( "border border-gray-400 dark:border-bluegray-600 dark:hover:border-bluegray-500 bg-white dark:bg-bluegray-700 mt-2", index /= 0 )
                , ( "bg-yellow-50 dark:bg-lime-900 mt-4", dropActive )
                ]
             , id ("merge-" ++ item.id)
             ]
                ++ draggable DragDrop index
            )
            [ div
                [ class "mr-2 sm:rounded-l w-16 bg-white"
                , classList [ ( "hidden", fieldHidden Data.Fields.PreviewImage ) ]
                ]
                [ img
                    [ class "preview-image mx-auto pt-1"
                    , classList
                        [ ( "sm:rounded-l", True )
                        ]
                    , src previewUrl
                    ]
                    []
                ]
            , div [ class "flex-grow flex flex-col py-1 px-2" ]
                [ div [ class "flex flex-col sm:flex-row items-center" ]
                    [ div
                        [ class "font-bold text-lg"
                        , classList [ ( "hidden", IT.render titlePattern (templateCtx texts) item == "" ) ]
                        ]
                        [ dirIcon
                        , IT.render titlePattern (templateCtx texts) item |> text
                        ]
                    , div
                        [ classList
                            [ ( "opacity-75 sm:ml-2", True )
                            , ( "hidden", IT.render subtitlePattern (templateCtx texts) item == "" )
                            ]
                        ]
                        [ IT.render subtitlePattern (templateCtx texts) item |> text
                        ]
                    ]
                , mainData texts settings item
                , mainTagsAndFields2 settings item
                ]
            ]
        ]


mainData : Texts -> UiSettings -> ItemLight -> Html Msg
mainData texts settings item =
    let
        ctx =
            templateCtx texts

        corr =
            IT.render (Util.Item.corrTemplate settings) ctx item

        conc =
            IT.render (Util.Item.concTemplate settings) ctx item
    in
    div [ class "flex flex-row space-x-2" ]
        [ div
            [ classList
                [ ( "hidden", corr == "" )
                ]
            ]
            [ Icons.correspondentIcon2 "mr-1"
            , text corr
            ]
        , div
            [ classList
                [ ( "hidden", conc == "" )
                ]
            , class "ml-2"
            ]
            [ Icons.concernedIcon2 "mr-1"
            , text conc
            ]
        ]


mainTagsAndFields2 : UiSettings -> ItemLight -> Html Msg
mainTagsAndFields2 settings item =
    let
        fieldHidden f =
            Data.UiSettings.fieldHidden settings f

        hideTags =
            item.tags == [] || fieldHidden Data.Fields.Tag

        hideFields =
            item.customfields == [] || fieldHidden Data.Fields.CustomFields

        showTag tag =
            div
                [ class "label mt-1 font-semibold"
                , class (Data.UiSettings.tagColorString2 tag settings)
                ]
                [ i [ class "fa fa-tag mr-2" ] []
                , span [] [ text tag.name ]
                ]

        showField fv =
            Util.CustomField.renderValue2
                [ ( S.basicLabel, True )
                , ( "mt-1 font-semibold", True )
                ]
                Nothing
                fv

        renderFields =
            if hideFields then
                []

            else
                List.sortBy Util.CustomField.nameOrLabel item.customfields
                    |> List.map showField

        renderTags =
            if hideTags then
                []

            else
                List.map showTag item.tags
    in
    div
        [ classList
            [ ( "flex flex-row items-center flex-wrap text-xs font-medium my-1 space-x-2", True )
            , ( "hidden", hideTags && hideFields )
            ]
        ]
        (renderFields ++ renderTags)


renderFormState : Texts -> Model -> Html Msg
renderFormState texts model =
    case model.formState of
        FormStateInitial ->
            span [ class "hidden" ] []

        FormStateError msg ->
            div
                [ class S.errorMessage
                , class "py-2"
                ]
                [ text msg
                ]

        FormStateHttp err ->
            div
                [ class S.errorMessage
                , class "py-2"
                ]
                [ text (texts.httpError err)
                ]

        FormStateMergeSuccessful ->
            div
                [ class S.successMessage
                , class "py-2"
                ]
                [ text texts.mergeSuccessful
                ]


templateCtx : Texts -> IT.TemplateContext
templateCtx texts =
    { dateFormatLong = texts.formatDateLong
    , dateFormatShort = texts.formatDateShort
    , directionLabel = \_ -> ""
    }


droppable : (DDMsg -> msg) -> Int -> List (Attribute msg)
droppable tagger dropId =
    DD.droppable tagger dropId


draggable : (DDMsg -> msg) -> Int -> List (Attribute msg)
draggable tagger itemId =
    DD.draggable tagger itemId


getDropId : Model -> Maybe Int
getDropId model =
    DD.getDropId model.dragDrop


getDragId : Model -> Maybe Int
getDragId model =
    DD.getDragId model.dragDrop
