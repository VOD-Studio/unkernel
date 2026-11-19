// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// The launcher's demos, one file each, in the order the menu lists them.
// A new demo: a file here that default-exports a Demo (launcher.ts), added below.
import type { Demo } from "../launcher.ts";
import aquarium from "./aquarium.ts";
import doom from "./doom.ts";
import dos from "./dos.ts";
import git from "./git.ts";
import glimmer from "./glimmer.ts";
import htop from "./htop.ts";
import mc from "./mc.ts";
import nginx from "./nginx.ts";
import nitro from "./nitro.ts";
import node from "./node.ts";
import nvim from "./nvim.ts";
import postgres from "./postgres.ts";
import python from "./python.ts";
import radio from "./radio.ts";
import speak from "./speak.ts";
import sqlite from "./sqlite.ts";
import sshfs from "./sshfs.ts";
import tmux from "./tmux.ts";
import ubuntu from "./ubuntu.ts";
import valkey from "./valkey.ts";
import windows from "./windows.ts";

export const DEMOS: Demo[] = [glimmer, tmux, htop, mc, nvim, git, ubuntu, sshfs, nginx, node, nitro, python, postgres, sqlite, valkey, radio, speak, aquarium, dos, doom, windows];
