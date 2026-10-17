// © GoodHatsLLC

#if os(iOS)
  import AIOSupport
  import AVFAudio
  import Foundation
  import Tools
  import os

  private let audioEnvironmentLifecycleLog = SystemLog.make()

  extension AudioEnvironmentManager {
    package struct AudioEnvironmentLifecycleRuntime {
      let owner: AudioEnvironmentManager

      @MainActor
      private func subscribeToOrientation(
        _ onChange: @MainActor (AVAudioSession.StereoOrientation) async -> Void,
      ) async {
        let deviceInfo = PlatformDevice.create()

        let initial = await deviceInfo.currentOrientation
        await onChange(initial.avAudioSessionOrientation)

        for await orientation in deviceInfo.orientationChanges() {
          await onChange(orientation.avAudioSessionOrientation)
        }
      }

      @MainActor
      func run(sessionConfiguration: AudioSessionConfiguration) async throws(ManagerError) {
        guard !owner.isRunning else {
          throw .alreadyRunning
        }
        audioEnvironmentLifecycleLog.info("🔊 AudioEnvironmentManager.run() started")

        owner.isRunning = true
        defer { await finish() }

        var isConfigured = false
        var configureAttempt = 0
        let configureRetryPolicy = RetryPolicy(
          maxAttempts: .max,
          delay: .exponential(
            base: .milliseconds(100),
            maximum: .seconds(2),
            maximumExponent: 10,
          ),
        )
        while !isConfigured {
          configureAttempt += 1
          do {
            try await owner.sessionBootstrap.configureInitialSession(
              configuration: sessionConfiguration,
            )
            isConfigured = true
          } catch {
            if Task.isCancelled {
              return
            }

            let configureRetryDelay = configureRetryPolicy.retryDelay(
              afterFailureCount: configureAttempt,
            )
            audioEnvironmentLifecycleLog.error(
              """
              Engine failed to configure audio session (attempt \(configureAttempt, privacy: .public)):
              \(String(describing: error), privacy: .public)
              Retrying in \(configureRetryDelay, privacy: .public)
              """,
            )
            try? await configureRetryPolicy.wait(afterFailureCount: configureAttempt)
          }
        }

        await subscribe()

      }

      @MainActor
      private func finish() async {
        await withTaskCancellationShield {
          if owner.isAudioSessionActive {
            do {
              try await owner.setAudioSessionActive(false)
            } catch {
              audioEnvironmentLifecycleLog.error(
                "Failed to deactivate AudioSession on shutdown: \(error, privacy: .public)",
              )
            }
          }
          owner.isRunning = false
          audioEnvironmentLifecycleLog.info("🔇 AudioEnvironmentManager.run() finished")
        }
      }

      /// Subscribes to all AVAudioSession notification streams.
      ///
      /// ## Threading Contract
      ///
      /// Each `for await` loop consumes an `AsyncStream` from
      /// ``AudioEnvironment/Notifications``. The stream's `compactMap`/`map` closures
      /// execute on Apple's internal "AVAudioSession Notify Thread" (parsing only,
      /// no mutable state). The `for await` body inherits this method's `@MainActor`
      /// isolation, so all handlers dispatch to MainActor automatically.
      @MainActor
      private func subscribe() async {
        await withTaskGroup(of: Void.self) { group in
          let env = owner.env

          group.addTask { [weak owner] in
            for await notification in env.notifications.interruption {
              if Task.isCancelled { return }

              switch notification.type {
              case .began:
                await owner?.dispatchAudioSystemEvent(.interruptionBegan)
              case .ended:
                await owner?.dispatchAudioSystemEvent(
                  .interruptionEnded(
                    shouldResume: notification.options?.contains(.shouldResume) == true,
                  ),
                )
              @unknown default:
                continue
              }
            }
          }
          // Session-state confirmations supplement interruption notifications.
          group.addTask { [self] in
            for await _ in env.notifications.sessionDidBecomeActive {
              if Task.isCancelled { return }
              await handleSessionDidBecomeActive()
            }
          }
          group.addTask { [self] in
            for await deactivation in env.notifications.sessionDidBecomeInactive {
              if Task.isCancelled { return }
              await handleSessionDidBecomeInactive(deactivation)
            }
          }
          group.addTask { [weak owner] in
            for await shouldResume in env.notifications.resumptionRecommendation {
              if Task.isCancelled { return }
              await owner?.dispatchAudioSystemEvent(.resumptionRecommended(shouldResume))
            }
          }
          group.addTask { [self] in
            for await _ in env.notifications.mediaServicesLost {
              if Task.isCancelled { return }
              await handleMediaServicesLost()
            }
          }
          group.addTask { [self] in
            for await _ in env.notifications.mediaServicesReset {
              if Task.isCancelled { return }
              await handleMediaServicesReset()
            }
          }
          owner.routeObserver.addTasks(to: &group)
          group.addTask { [self] in
            await self.subscribeToOrientation { @MainActor [weak owner] orientation in
              guard let owner else { return }
              audioEnvironmentLifecycleLog.info(
                "orientation changed to: \(orientation.rawValue, privacy: .public)",
              )
              await owner.updateOrientation(orientation)
            }
          }

          group.addTask { @Sendable @MainActor [weak owner] in
            while !Task.isCancelled {
              guard let owner else { return }
              let pollInterval: Duration
              if owner.isAudioSessionActive {
                await owner.reconcileInputConfiguration()
                pollInterval = .seconds(15)
              } else {
                await owner.reconcileInputConfiguration()
                pollInterval = .seconds(30)
              }
              let pollingPolicy = PollingPolicy(interval: pollInterval)
              try? await pollingPolicy.waitForNextPoll()
            }
          }

          owner.isReady = true
          audioEnvironmentLifecycleLog.info("🔊 AudioEnvironmentManager ready")
          defer {
            owner.isReady = false
            audioEnvironmentLifecycleLog.info("🔇AudioEnvironmentManager cancelled")
          }
          await group.waitForAll()
        }
      }

      /// Confirmation signal. Reconciles applied state when it disagrees — an
      /// activation the controller did not perform still leaves the platform
      /// active, and the mirror must follow the platform, not the other way
      /// round.
      @MainActor
      private func handleSessionDidBecomeActive() async {
        if !owner.isAudioSessionActive {
          audioEnvironmentLifecycleLog.warning(
            "sessionDidBecomeActive while applied state was inactive; reconciling",
          )
          owner.isAudioSessionActive = true
          owner.requestedAudioSessionActive = true
          await owner.reconcileInputConfiguration(forcePlatformApply: true)
        }
        await owner.dispatchAudioSystemEvent(.sessionActivated)
      }

      /// The platform has already deactivated, whatever the controller
      /// believes, so applied state is forced to `false` — the same treatment
      /// media-services loss gets.
      @MainActor
      private func handleSessionDidBecomeInactive(
        _ deactivation: AudioSessionDeactivation,
      ) async {
        audioEnvironmentLifecycleLog.warning(
          "sessionDidBecomeInactive: \(deactivation.userLabel, privacy: .public)",
        )
        owner.isAudioSessionActive = false
        owner.requestedAudioSessionActive = false
        owner.markInputConfigurationUnavailable(.sessionInactive)
        await owner.dispatchAudioSystemEvent(.sessionDeactivated(deactivation))
      }

      @MainActor
      private func handleMediaServicesLost() async {
        audioEnvironmentLifecycleLog.warning(
          "mediaServicesLost notification: audio services unavailable",
        )
        owner.isAudioSessionActive = false
        owner.requestedAudioSessionActive = false
        owner.markInputConfigurationUnavailable(.mediaServicesUnavailable)
        await owner.dispatchAudioSystemEvent(.mediaServicesLost)
      }

      @MainActor
      private func handleMediaServicesReset() async {
        audioEnvironmentLifecycleLog.warning(
          "mediaServicesReset notification: rebuilding audio session configuration",
        )
        owner.isAudioSessionActive = false
        owner.requestedAudioSessionActive = false
        do {
          try owner.sessionBootstrap.rebuildSessionConfiguration(
            configuration: owner.sessionConfiguration,
          )
        } catch {
          owner.errorManager.enqueue(error)
        }
        // Media services came back with the session rebuilt from scratch, so
        // nothing the coordinator previously observed still describes the
        // platform. This is one of the deliberate forced writes; the write
        // barrier absorbs the route notification it produces.
        await owner.reconcileInputConfiguration(forcePlatformApply: true)
        await owner.dispatchAudioSystemEvent(.mediaServicesReset)
      }
    }
  }
#endif
