/** Title -> path-style breadcrumb segment: "Audit deck" -> "audit-deck" */
export const slug = (t: string): string => t.trim().toLowerCase().replace(/\s+/g, "-") || "untitled";
