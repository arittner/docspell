/*
 * Copyright 2020 Eike K. & Contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

package docspell.backend.ops

import cats.effect.{Async, Resource}
import cats.implicits._
import fs2.Stream

import docspell.backend.JobFactory
import docspell.backend.PasswordCrypt
import docspell.backend.ops.OCollective._
import docspell.common._
import docspell.scheduler.JobStore
import docspell.scheduler.usertask.{UserTask, UserTaskScope, UserTaskStore}
import docspell.store.UpdateResult
import docspell.store.queries.{QCollective, QUser}
import docspell.store.records._
import docspell.store.{AddResult, Store}

import com.github.eikek.calev._

trait OCollective[F[_]] {

  def find(name: Ident): F[Option[RCollective]]

  def updateSettings(collective: Ident, settings: OCollective.Settings): F[AddResult]

  def findSettings(collective: Ident): F[Option[OCollective.Settings]]

  def listUser(collective: Ident): F[Vector[RUser]]

  def add(s: RUser): F[AddResult]

  def update(s: RUser): F[AddResult]

  /** Deletes the user and all its data. */
  def deleteUser(login: Ident, collective: Ident): F[UpdateResult]

  /** Return an excerpt of what would be deleted, when the user is deleted. */
  def getDeleteUserData(accountId: AccountId): F[DeleteUserData]

  def insights(collective: Ident): F[InsightData]

  def tagCloud(collective: Ident): F[List[TagCount]]

  def changePassword(
      accountId: AccountId,
      current: Password,
      newPass: Password
  ): F[PassChangeResult]

  def resetPassword(accountId: AccountId): F[PassResetResult]

  def getContacts(
      collective: Ident,
      query: Option[String],
      kind: Option[ContactKind]
  ): Stream[F, RContact]

  def findEnabledSource(sourceId: Ident): F[Option[RSource]]

  def addPassword(collective: Ident, pw: Password): F[Unit]

  def getPasswords(collective: Ident): F[List[RCollectivePassword]]

  def removePassword(id: Ident): F[Unit]

  def startLearnClassifier(collective: Ident): F[Unit]

  def startEmptyTrash(args: EmptyTrashArgs): F[Unit]

  /** Submits a task that (re)generates the preview images for all attachments of the
    * given collective.
    */
  def generatePreviews(
      storeMode: MakePreviewArgs.StoreMode,
      account: AccountId
  ): F[UpdateResult]
}

object OCollective {

  type TagCount = docspell.store.queries.TagCount
  val TagCount = docspell.store.queries.TagCount

  type CategoryCount = docspell.store.queries.CategoryCount
  val CategoryCount = docspell.store.queries.CategoryCount

  type InsightData = QCollective.InsightData
  val insightData = QCollective.InsightData

  type Settings = RCollective.Settings
  val Settings = RCollective.Settings
  type Classifier = RClassifierSetting.Classifier
  val Classifier = RClassifierSetting.Classifier
  type EmptyTrash = REmptyTrashSetting.EmptyTrash
  val EmptyTrash = REmptyTrashSetting.EmptyTrash

  type DeleteUserData = QUser.UserData
  val DeleteUserData = QUser.UserData

  sealed trait PassResetResult
  object PassResetResult {
    case class Success(newPw: Password) extends PassResetResult
    case object NotFound extends PassResetResult
    case object UserNotLocal extends PassResetResult

    def success(np: Password): PassResetResult = Success(np)
    def notFound: PassResetResult = NotFound
    def userNotLocal: PassResetResult = UserNotLocal
  }

  sealed trait PassChangeResult
  object PassChangeResult {
    case object UserNotFound extends PassChangeResult
    case object PasswordMismatch extends PassChangeResult
    case object UpdateFailed extends PassChangeResult
    case object UserNotLocal extends PassChangeResult
    case object Success extends PassChangeResult

    def userNotFound: PassChangeResult = UserNotFound
    def passwordMismatch: PassChangeResult = PasswordMismatch
    def success: PassChangeResult = Success
    def updateFailed: PassChangeResult = UpdateFailed
    def userNotLocal: PassChangeResult = UserNotLocal
  }

  def apply[F[_]: Async](
      store: Store[F],
      uts: UserTaskStore[F],
      jobStore: JobStore[F],
      joex: OJoex[F]
  ): Resource[F, OCollective[F]] =
    Resource.pure[F, OCollective[F]](new OCollective[F] {
      def find(name: Ident): F[Option[RCollective]] =
        store.transact(RCollective.findById(name))

      def updateSettings(collective: Ident, sett: Settings): F[AddResult] =
        store
          .transact(RCollective.updateSettings(collective, sett))
          .attempt
          .map(AddResult.fromUpdate)
          .flatMap(res =>
            updateLearnClassifierTask(collective, sett) *> updateEmptyTrashTask(
              collective,
              sett
            ) *> res.pure[F]
          )

      private def updateLearnClassifierTask(coll: Ident, sett: Settings): F[Unit] =
        for {
          id <- Ident.randomId[F]
          on = sett.classifier.exists(_.enabled)
          timer = sett.classifier.map(_.schedule).getOrElse(CalEvent.unsafe(""))
          args = LearnClassifierArgs(coll)
          ut = UserTask(
            id,
            LearnClassifierArgs.taskName,
            on,
            timer,
            None,
            args
          )
          _ <- uts.updateOneTask(UserTaskScope(coll), args.makeSubject.some, ut)
          _ <- joex.notifyAllNodes
        } yield ()

      private def updateEmptyTrashTask(coll: Ident, sett: Settings): F[Unit] =
        for {
          id <- Ident.randomId[F]
          settings = sett.emptyTrash.getOrElse(EmptyTrash.default)
          args = EmptyTrashArgs(coll, settings.minAge)
          ut = UserTask(id, EmptyTrashArgs.taskName, true, settings.schedule, None, args)
          _ <- uts.updateOneTask(UserTaskScope(coll), args.makeSubject.some, ut)
          _ <- joex.notifyAllNodes
        } yield ()

      def addPassword(collective: Ident, pw: Password): F[Unit] =
        for {
          cpass <- RCollectivePassword.createNew[F](collective, pw)
          _ <- store.transact(RCollectivePassword.upsert(cpass))
        } yield ()

      def getPasswords(collective: Ident): F[List[RCollectivePassword]] =
        store.transact(RCollectivePassword.findAll(collective))

      def removePassword(id: Ident): F[Unit] =
        store.transact(RCollectivePassword.deleteById(id)).map(_ => ())

      def startLearnClassifier(collective: Ident): F[Unit] =
        for {
          id <- Ident.randomId[F]
          args = LearnClassifierArgs(collective)
          ut = UserTask(
            id,
            LearnClassifierArgs.taskName,
            true,
            CalEvent(WeekdayComponent.All, DateEvent.All, TimeEvent.All),
            None,
            args
          )
          _ <- uts
            .executeNow(UserTaskScope(collective), args.makeSubject.some, ut)
        } yield ()

      def startEmptyTrash(args: EmptyTrashArgs): F[Unit] =
        for {
          id <- Ident.randomId[F]
          ut = UserTask(
            id,
            EmptyTrashArgs.taskName,
            true,
            CalEvent(WeekdayComponent.All, DateEvent.All, TimeEvent.All),
            None,
            args
          )
          _ <- uts
            .executeNow(UserTaskScope(args.collective), args.makeSubject.some, ut)
        } yield ()

      def findSettings(collective: Ident): F[Option[OCollective.Settings]] =
        store.transact(RCollective.getSettings(collective))

      def listUser(collective: Ident): F[Vector[RUser]] =
        store.transact(RUser.findAll(collective, _.login))

      def add(s: RUser): F[AddResult] =
        if (s.source != AccountSource.Local)
          AddResult.failure(new Exception("Only local accounts can be created!")).pure[F]
        else
          store.add(
            RUser.insert(s.copy(password = PasswordCrypt.crypt(s.password))),
            RUser.exists(s.login)
          )

      def update(s: RUser): F[AddResult] =
        store.add(RUser.update(s), RUser.exists(s.login))

      def getDeleteUserData(accountId: AccountId): F[DeleteUserData] =
        store.transact(QUser.getUserData(accountId))

      def deleteUser(login: Ident, collective: Ident): F[UpdateResult] =
        UpdateResult.fromUpdate(
          store.transact(QUser.deleteUserAndData(AccountId(collective, login)))
        )

      def insights(collective: Ident): F[InsightData] =
        store.transact(QCollective.getInsights(collective))

      def tagCloud(collective: Ident): F[List[TagCount]] =
        store.transact(QCollective.tagCloud(collective))

      def resetPassword(accountId: AccountId): F[PassResetResult] =
        for {
          newPass <- Password.generate[F]
          optUser <- store.transact(RUser.findByAccount(accountId))
          n <- store.transact(
            RUser.updatePassword(accountId, PasswordCrypt.crypt(newPass))
          )
          res =
            if (optUser.exists(_.source != AccountSource.Local))
              PassResetResult.userNotLocal
            else if (n <= 0) PassResetResult.notFound
            else PassResetResult.success(newPass)
        } yield res

      def changePassword(
          accountId: AccountId,
          current: Password,
          newPass: Password
      ): F[PassChangeResult] = {
        val q = for {
          optUser <- RUser.findByAccount(accountId)
          check = optUser.map(_.password).map(p => PasswordCrypt.check(current, p))
          n <-
            check
              .filter(identity)
              .traverse(_ =>
                RUser.updatePassword(accountId, PasswordCrypt.crypt(newPass))
              )
          res = check match {
            case Some(true) =>
              if (n.getOrElse(0) > 0) PassChangeResult.success
              else if (optUser.exists(_.source != AccountSource.Local))
                PassChangeResult.userNotLocal
              else PassChangeResult.updateFailed
            case Some(false) =>
              PassChangeResult.passwordMismatch
            case None =>
              PassChangeResult.userNotFound
          }
        } yield res

        store.transact(q)
      }

      def getContacts(
          collective: Ident,
          query: Option[String],
          kind: Option[ContactKind]
      ): Stream[F, RContact] =
        store.transact(QCollective.getContacts(collective, query, kind))

      def findEnabledSource(sourceId: Ident): F[Option[RSource]] =
        store.transact(RSource.findEnabled(sourceId))

      def generatePreviews(
          storeMode: MakePreviewArgs.StoreMode,
          account: AccountId
      ): F[UpdateResult] =
        for {
          job <- JobFactory.allPreviews[F](
            AllPreviewsArgs(Some(account.collective), storeMode),
            Some(account.user)
          )
          _ <- jobStore.insertIfNew(job.encode)
        } yield UpdateResult.success

    })
}
