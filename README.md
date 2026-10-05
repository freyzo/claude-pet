# claude-pet

Desktop pets + an AI chat on macOS.

![demo](./docs/media/stitchAgent.gif)
![claude](./docs/media/claude.png)

Two naughty little pets roam your desktop.
Click one to chat with GitHub Copilot or Claude Code. Hover it to say hi.

## What It Does

- Two pets, Stitch and the Claude robot: zoomies, hops, wiggle dances, sneaking around, chasing your cursor (and sometimes running away from it)
- They hop out of your way when your cursor rests on them
- **Cozy Corner**: send a pet to a bottom corner, where it keeps playing without getting in your way
- Click a pet to chat; replies come in easy-to-read chat bubbles with the pet's avatar
- Pick the assistant: **GitHub Copilot** (default) or **Claude Code** (menu bar icon → **Assistant**)
- Name your pets whatever you like (menu bar icon → **Rename Pet**)
- **Pause Pets** (⌘P); pets also calm down on Low Power Mode, Reduce Motion, or when your Mac is hot
- Draggable pets and chat box (they stay where you drop them)
- Styles, sounds, and a choice of display

## Requirements

- macOS 14+
- To chat, one of:
  - [GitHub Copilot CLI](https://github.com/github/copilot-cli), installed and logged in (`brew install --cask copilot-cli`, then `copilot login`)
  - [Claude Code](https://claude.ai/download), installed and logged in

Without either, the pets still work; the chat shows **offline** with a one-click fix to install or log in.

## Quick Start

1. Go to [Releases](https://github.com/freyzo/claude-pet/releases)
2. Download the latest `.dmg`
3. Open the DMG and move `claude-pet` to `Applications`
4. The app isn't notarized yet, so the first time: right-click `claude-pet` in `Applications` → **Open** → **Open**

Or build from source (needs Xcode):

1. Run `./scripts/build --open`, or open `claude-pet.xcodeproj` in Xcode and run the `claude-pet` scheme
2. Look for the pet icon in your menu bar

## Heads-up: The Assistant Can Change Files

With **Allow Edits & Commands** on (the default), the assistant can run commands and create, edit or delete files in its folder **without asking first**. It starts in your home folder; pick another one from menu bar icon → **Assistant** → **Choose Folder…**. Turn **Allow Edits & Commands** off for read-only chat.

## Privacy

- No analytics, no account with this app
- The pets run entirely on your Mac
- Chat goes through your local Copilot CLI or Claude Code, which send your messages to GitHub or Anthropic
- The app checks for updates in the background (Sparkle)


