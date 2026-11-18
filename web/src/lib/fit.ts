/** Font scales tried from largest to smallest; the last is the floor. */
export const SCALES = [1, 0.92, 0.85, 0.78, 0.71, 0.65, 0.59, 0.54, 0.5, 0.46, 0.42];

export interface Measure { scrollHeight: number; clientHeight: number }

/** First scale whose measured content fits its box; the floor if none does. */
export function fitScale(measure: (scale: number) => Measure, scales: number[] = SCALES): number {
  for (const s of scales) {
    const m = measure(s);
    if (m.scrollHeight <= m.clientHeight) return s;
  }
  return scales[scales.length - 1];
}
