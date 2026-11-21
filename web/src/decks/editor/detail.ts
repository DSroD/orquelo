import type { Poll, Presentation, Session } from "../../lib/types";

export type Detail = Presentation & { polls: Poll[]; sessions: Session[]; disabled?: true };
