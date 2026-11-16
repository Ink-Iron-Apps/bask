package com.inknironapps.bask.libmpv

data class LogMessage(
  val prefix: String,
  val level: LogLevel,
  val text: String
)
