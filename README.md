# claude-pet

Desktop pet + Claude CLI on macOS.

![demo](./docs/media/stitchAgent.gif)
![claude](./docs/media/claude.png)

A naughty little pet roams your desktop.
Click it to chat with Claude Code. Hover it to say hi.

## What It Does

- A Stitch pet that roams your desktop: zoomies, hops, wiggle dances, sneaking around, chasing your cursor (and sometimes running away from it)
- Hover reactions with sounds
- Click to open a chat with [Claude Code](https://claude.ai/download); the pet sits still while you chat
- Name your pet whatever you like (menu bar icon → **Rename Pet…**)
- Draggable pet and chat box (they stay where you drop them)
- Styles, sounds, and a choice of display

## Requirements

- macOS 14+
- To chat: [Claude Code](https://claude.ai/download), installed and logged in (Claude account or API key)

Without Claude Code the pet still works; the chat shows **offline** with a one-click fix to install Claude Code or log in.

## Quick Start

1. Go to [Releases](https://github.com/freyzo/claude-pet/releases)
2. Download the latest `.dmg`
3. Open the DMG and move `claude-pet` to `Applications`
4. Launch `claude-pet` from `Applications`

Or build from source (needs Xcode):

1. Run `./scripts/build --open`, or open `claude-pet.xcodeproj` in Xcode and run the `claude-pet` scheme
2. Look for the pet icon in your menu bar

## Heads-up: Claude Can Change Files

The chat runs Claude Code with `--dangerously-skip-permissions`, starting in your home folder. Claude can run commands and create, edit or delete files **without asking first**. Only ask for things you'd be happy for it to do unattended.

## Privacy

- No analytics, no account with this app
- The pet runs entirely on your Mac
- Chat goes through your local Claude Code, which sends your messages to Anthropic
- The app checks for updates in the background (Sparkle)


