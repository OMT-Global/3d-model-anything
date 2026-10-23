/** Shared guards for buttons, initial URLs, and room transitions. */
export type ViewerMode = 'orbit' | 'walk' | 'layout' | 'knolling';
export function viewerModeForRoom(previewOnly: boolean | undefined, mode: ViewerMode): ViewerMode {
  return previewOnly && (mode === 'walk' || mode === 'knolling') ? 'orbit' : mode;
}
export function playgroundRoom<T extends { id: string; previewOnly?: boolean }>(rooms: T[], id: string | null): T {
  const playable = rooms.filter(room => !room.previewOnly);
  const room = playable.find(room => room.id === id) ?? playable[0];
  if (!room) throw new Error('No playable room is registered');
  return room;
}
