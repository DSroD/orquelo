import { expect, it } from "vitest";
import { ApiError } from "./api";
import { loginRedirect } from "./expired";

it("redirects to login on 401 only", () => {
  expect(loginRedirect(new ApiError(401, "unauthorized", "x"), "/sessions/abc")).toBe("/login?return_to=%2Fsessions%2Fabc");
  expect(loginRedirect(new ApiError(500, "internal", "x"), "/a")).toBeNull();
  expect(loginRedirect(new TypeError("network"), "/a")).toBeNull();
});
