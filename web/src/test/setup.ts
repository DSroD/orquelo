import { vi } from "vitest";

// pdf.js needs a real canvas and a worker; components only need to know a document is still loading
vi.mock("../lib/pdf", () => ({ loadPdf: () => new Promise(() => {}), pageCountOf: async () => 1 }));

globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} };
