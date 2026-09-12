import 'dart:math';

// The commercial module's public barrel. Prefixed because the barrel
// re-exports module-level names (e.g. the generated `Protocol`/`Endpoints`
// classes) that collide with the host's. The generated
// `ServerpodFutureCallsGetter` extension is hidden because its name collides
// with the host-generated extension of the same name (affects
// `pod.futureCalls`); the host's copy must win.
import 'package:gewerber_backend_commercial_server/gewerber_backend_commercial_server.dart'
    as commercial
    hide ServerpodFutureCallsGetter;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_idp_server/core.dart';
import 'package:serverpod_auth_idp_server/providers/email.dart';

import 'src/core/di/injection.dart';
import 'src/core/di/service_locator.dart';
import 'src/core/mail/email_template.dart';
import 'src/core/mail/mail_service.dart';
import 'src/generated/endpoints.dart';
import 'src/generated/protocol.dart';
import 'src/modules/invoicing/jobs/invoicing_job_scheduler.dart';

/// The starting point of the Serverpod server.
void run(List<String> args) async {
  // Initialize Serverpod and connect it with your generated code.
  final pod = Serverpod(args, Protocol(), Endpoints());

  await configureDependencies();

  // Initialize authentication services for the server.
  // Token managers will be used to validate and issue authentication keys,
  // and the identity providers will be the authentication options available for users.
  pod.initializeAuthServices(
    tokenManagerBuilders: [
      // Use JWT for authentication keys towards the server.
      JwtConfigFromPasswords(),
    ],
    identityProviderBuilders: [
      // Configure the email identity provider for email/password authentication.
      // Verification codes are sent by MailService via SMTP (settings read from
      // `config/passwords.yaml`). If no SMTP host is configured, the codes are
      // only logged, which keeps the flow usable in local development.
      EmailIdpConfigFromPasswords(
        registrationVerificationCodeGenerator: _generateVerificationCode,
        passwordResetVerificationCodeGenerator: _generateVerificationCode,
        sendRegistrationVerificationCode:
            (
              session, {
              required email,
              required accountRequestId,
              required verificationCode,
              required transaction,
            }) {
              return getIt<MailService>().sendVerificationCode(
                session,
                email: email,
                verificationCode: verificationCode,
                template: EmailTemplate.registrationVerification,
              );
            },
        sendPasswordResetVerificationCode:
            (
              session, {
              required email,
              required passwordResetRequestId,
              required verificationCode,
              required transaction,
            }) {
              return getIt<MailService>().sendVerificationCode(
                session,
                email: email,
                verificationCode: verificationCode,
                template: EmailTemplate.passwordResetVerification,
              );
            },
      ),
    ],
  );

  // Commercial billing wiring (PayPal webhook route + hourly reconciliation
  // sweep), provided by the closed-source module's public entrypoint. A
  // complete no-op in the OSS default configuration (and with the public
  // stubs, which ship an identical no-op). Runs before `pod.start()`
  // because the Relic-based web server binds its routes when it starts.
  await commercial.wireCommercialBilling(pod);

  // Start the server.
  await pod.start();

  // Background jobs: materialize due recurring invoices and mark overdue
  // invoices periodically.
  await const InvoicingJobScheduler().ensureScheduled(pod.futureCalls);
}

/// Length of the email verification codes (registration + password reset).
/// 8 digits give 10^8 combinations — brute-force resistant enough for a
/// rate-limited, expiring code without being unreadable for users.
///
/// Contract: the client app (gewerber-app) must accept codes of this exact
/// length. The value is mirrored in `AppConstants.verificationCodeLength`
/// in the app, but the two packages cannot share a Dart import.
const int _verificationCodeLength = 8;

/// Generates a numeric verification code of [_verificationCodeLength]
/// digits. The code length is set here because the email IdP takes the
/// generator function as configuration (the IdP default is also 8 digits;
/// keeping an explicit generator documents the contract).
String _generateVerificationCode() {
  const digits = '0123456789';
  final random = Random.secure();
  return String.fromCharCodes(
    Iterable.generate(
      _verificationCodeLength,
      (_) => digits.codeUnitAt(random.nextInt(digits.length)),
    ),
  );
}
