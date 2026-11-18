import { mount } from "svelte";
import "./app.css";
import "./term.css";
import App from "./App.svelte";

mount(App, { target: document.getElementById("app")! });
