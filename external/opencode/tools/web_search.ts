/**
 * OpenCode custom tool: web_search
 *
 * The file lives under `tools/`, but it resolves `@opencode-ai/plugin`
 * from XDG config directly so it still works when Home Manager symlinks
 * this file from the repo into `~/.config/opencode/tools`.
 */

import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  WebSearchClient,
  WEB_SEARCH_DESCRIPTION,
  buildWebSearchArgShape,
} from "../tools-lib/ol-core.js";

function getPluginModuleUrl(): string {
  const configHome = process.env.XDG_CONFIG_HOME ?? path.join(process.env.HOME ?? "", ".config");

  return pathToFileURL(
    path.join(configHome, "opencode", "node_modules", "@opencode-ai", "plugin", "dist", "index.js"),
  ).href;
}

const { tool } = (await import(getPluginModuleUrl())) as typeof import("@opencode-ai/plugin");

const client = new WebSearchClient({
  baseUrl:
    process.env.OCTANE_LLM_PROXY_URL ||
    process.env.OCTANE_BASE_URL ||
    undefined,
});

export default tool({
  description: WEB_SEARCH_DESCRIPTION,
  args: buildWebSearchArgShape(tool.schema) as Parameters<typeof tool>[0]["args"],
  async execute(args) {
    const result = await client.search(args);
    return result.formatted;
  },
});
