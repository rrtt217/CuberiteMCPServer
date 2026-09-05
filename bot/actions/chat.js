'use strict'
// bot/actions/chat.js — chat + server command + chat buffer
module.exports = function chatActions(botCtl) {
  return {
    sendChat(text) {
      return botCtl.sendChat(text)
    },
    say(text) { return botCtl.sendChat(text) },
    chatHistory(limit) {
      const arr = botCtl.chatBuffer.slice(-(limit || 50))
      return { success: true, data: { count: arr.length, messages: arr.slice() } }
    },
  }
}
