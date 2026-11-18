const two = (n: number) => String(n).padStart(2, "0");

/** ISO instant -> local "YYYY-MM-DD" */
export function localDate(iso: string): string {
  const d = new Date(iso);
  return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}`;
}

const hm = new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });

/** ISO instant -> local 24 h "HH:MM" */
export const localTime = (iso: string): string => hm.format(new Date(iso));

/** ISO instant -> local "YYYY-MM-DD HH:MM" */
export const localDateTime = (iso: string): string => `${localDate(iso)} ${localTime(iso)}`;
