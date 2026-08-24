// WebSocket 连接注册表：按用户名维护在线 socket，用于把新消息推送给会话成员。

import WebSocket from 'ws';

const byUser = new Map<string, Set<WebSocket>>();

export function register(username: string, socket: WebSocket): void {
  if (!byUser.has(username)) byUser.set(username, new Set());
  byUser.get(username)!.add(socket);
}

export function unregister(username: string, socket: WebSocket): void {
  byUser.get(username)?.delete(socket);
}

/** 把 JSON 数据推送给给定用户名列表里所有在线连接。 */
export function sendToUsers(usernames: Iterable<string>, data: unknown): void {
  const text = JSON.stringify(data);
  for (const id of usernames) {
    for (const s of byUser.get(id) ?? []) {
      if (s.readyState === WebSocket.OPEN) s.send(text);
    }
  }
}
