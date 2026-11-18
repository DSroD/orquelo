import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/svelte";
import userEvent from "@testing-library/user-event";
import PollForm from "./PollForm.svelte";
import { fixture } from "../test/net";
import type { Poll } from "../lib/types";

const user = userEvent.setup();

describe("Poll configuration", () => {
  it("saves exclusive flags together with option labels and live additions", async () => {
    const onsave = vi.fn(async () => {});
    render(PollForm, { poll: fixture<Poll>("poll"), pdf: "/test.pdf", pageCount: 42, onsave, oncancel: () => {} });
    await user.click(screen.getAllByRole("checkbox", { name: "Exclusive" })[1]);
    await user.click(screen.getByRole("checkbox", { name: "Allow additional answers during voting" }));
    await user.click(screen.getByRole("button", { name: "Save poll" }));
    expect(onsave).toHaveBeenCalledWith(expect.objectContaining({
      allow_additional_answers: true,
      options: [{ label: "square", exclusive: false }, { label: "random", exclusive: true }, { label: "string-append", exclusive: false }],
    }));
  });

  it("clears exclusivity in the payload when switched to single choice", async () => {
    const poll = fixture<Poll>("poll");
    poll.options[0].exclusive = true;
    const onsave = vi.fn(async () => {});
    render(PollForm, { poll, pdf: "/test.pdf", pageCount: 42, onsave, oncancel: () => {} });
    await user.selectOptions(screen.getByRole("combobox", { name: "Type" }), "single");
    expect(screen.queryByRole("checkbox", { name: "Exclusive" })).toBeNull();
    await user.click(screen.getByRole("button", { name: "Save poll" }));
    expect(onsave).toHaveBeenCalledWith(expect.objectContaining({ kind: "single", options: poll.options.map((o) => ({ label: o.label, exclusive: false })) }));
  });
});
