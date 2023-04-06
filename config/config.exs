# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
import Config

config :logger,
  utc_log: true,
  handle_otp_reports: true,
  handle_sasl_reports: true,
  backends: [
    RingLogger
  ],
  level: :debug
