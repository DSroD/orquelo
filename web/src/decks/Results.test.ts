import { afterEach, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import Results from "./Results.svelte";
import { fixture, stubFetch } from "../test/net";
import type { AudienceSnapshot, SessionResults } from "../lib/types";

afterEach(() => vi.unstubAllGlobals());

it("includes Q&A history and its own CSV download alongside poll results", async () => {
  const questions = fixture<AudienceSnapshot>("audience-qa").qa.questions;
  stubFetch(() => ({ ...fixture<SessionResults>("results"), qa: { enabled: true, questions } }));
  render(Results, { code: "abcde23456" });
  expect(await screen.findByRole("heading", { name: "Q&A" })).toBeTruthy();
  expect(screen.getByText(questions[0].text)).toBeTruthy();
  expect(screen.getByRole("link", { name: "Q&A CSV" }).getAttribute("href")).toBe("/api/sessions/abcde23456/qa.csv");
  expect(screen.getByRole("link", { name: "Results CSV" })).toBeTruthy();
});
