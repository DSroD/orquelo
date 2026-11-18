/** Compile-time exhaustiveness for switches and if-chains on a tagged union (see ScreenOverlay). */
export function assertNever(x: never): never {
  throw new Error(`unhandled variant: ${JSON.stringify(x)}`);
}
