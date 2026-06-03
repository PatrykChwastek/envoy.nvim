local M = {}

---@param bufnr number
function M.apply(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_call(bufnr, function()
    vim.cmd([==[
        syn clear
        let b:current_syntax = "http"

        " ── JSON body region ───────────────────────────────────────────
        " Defined first so HTTP structure rules win on their own lines.
        syn region  httpBody     start=/^[{[]/ end=/^[}\]]\s*$/ keepend extend fold
          \ contains=httpJsonString,httpJsonKey,httpJsonNumber,httpJsonBool,httpJsonNull,httpVarRef

        syn region  httpJsonString  start=/"/ skip=/\\"/ end=/"/ contained contains=httpJsonKey,httpVarRef
        syn match   httpJsonKey     /"[^"\\]*"\ze\s*:/ contained
        syn match   httpJsonNumber  /\b-\?\d\+\(\.\d\+\)\?\([eE][+-]\?\d\+\)\?\b/ contained
        syn keyword httpJsonBool    true false contained
        syn keyword httpJsonNull    null contained

        " ── HTTP structure ─────────────────────────────────────────────
        syn match httpSeparator /^###.*/
        syn match httpComment   /^#[^#].*/

        syn match httpMethod /^\%(GET\|POST\|PUT\|DELETE\|PATCH\|HEAD\|OPTIONS\|CONNECT\|TRACE\)\ze\s/
        syn match httpUrl    /^\%(GET\|POST\|PUT\|DELETE\|PATCH\|HEAD\|OPTIONS\|CONNECT\|TRACE\)\s\+\zs\S.*/

        syn match httpHeaderName  /^[A-Za-z][A-Za-z0-9\-]*\ze\s*:/
        syn match httpHeaderValue /^[A-Za-z][A-Za-z0-9\-]*\s*:\s*\zs.*/

        syn match httpVarDef /^@[A-Za-z_][A-Za-z0-9_]*/
        syn match httpVarRef /{{[^}]*}}/ containedin=ALL

        " ── Highlight links ────────────────────────────────────────────
        hi def link httpSeparator   Comment
        hi def link httpComment     Comment
        hi def link httpMethod      Keyword
        hi def link httpUrl         Underlined
        hi def link httpHeaderName  Identifier
        hi def link httpHeaderValue String
        hi def link httpVarDef      Type
        hi def link httpVarRef      Macro

        hi def link httpJsonKey     Identifier
        hi def link httpJsonString  String
        hi def link httpJsonNumber  Number
        hi def link httpJsonBool    Boolean
        hi def link httpJsonNull    Boolean
    ]==])
    end)
end

--- Apply syntax to the result buffer (no scheduling needed — custom filetype).
---@param bufnr number
function M.apply_result(bufnr)
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd([==[
            syn clear
            let b:current_syntax = "envoy-result"

            " ── Status line (first line) ───────────────────────────────
            " Colour the whole line by outcome, then pick out the code
            syn match resultOk    /^✓.*/
            syn match resultError /^✗.*/
            syn match resultWarn  /^\~.*/
            syn match resultCode2 /\%(✓[^H]*HTTP \)\zs2\d\d/ containedin=resultOk
            syn match resultCode4 /\%(✗[^H]*HTTP \)\zs[45]\d\d/ containedin=resultError
            syn match resultCode3 /\%(\~[^H]*HTTP \)\zs3\d\d/ containedin=resultWarn
            syn match resultMethod /\%(HTTP \d\d\d\s\+\)\zs\%(GET\|POST\|PUT\|DELETE\|PATCH\|HEAD\|OPTIONS\|CONNECT\|TRACE\)\ze\s/ containedin=resultOk,resultError,resultWarn

            " ── Section dividers ──────────────────────────────────────
            syn match resultDivider /^──.*─\+\s*$/

            " ── Response headers ──────────────────────────────────────
            syn match resultHeaderName  /^[A-Za-z][A-Za-z0-9\-]*\ze\s*:/
            syn match resultHeaderValue /^[A-Za-z][A-Za-z0-9\-]*\s*:\s*\zs.*/

            " ── ES hit / aggregation markers ──────────────────────────
            syn match resultEsHit  /^\s*\[.\{-}\]\s\+_index:.*$/
            syn match resultEsAgg  /^\s\+\S\+\s*:$/

            " ── JSON (global; structural patterns above take priority)
            syn match   resultJsonKey    /"[^"\\]*"\ze\s*:/
            syn region  resultJsonString start=/"/ skip=/\\"/ end=/"/ contains=resultJsonKey
            syn match   resultJsonNumber /\b-\?\d\+\(\.\d\+\)\?\([eE][+-]\?\d\+\)\?\b/
            syn keyword resultJsonBool   true false
            syn keyword resultJsonNull   null

            " ── Highlight links ───────────────────────────────────────
            hi def link resultOk          DiagnosticOk
            hi def link resultError       DiagnosticError
            hi def link resultWarn        DiagnosticWarn
            hi def link resultCode2       DiagnosticOk
            hi def link resultCode4       DiagnosticError
            hi def link resultCode3       DiagnosticWarn
            hi def link resultMethod      Keyword
            hi def link resultDivider     Comment
            hi def link resultHeaderName  Identifier
            hi def link resultHeaderValue String
            hi def link resultEsHit       Special
            hi def link resultEsAgg       Type
            hi def link resultJsonKey     Identifier
            hi def link resultJsonString  String
            hi def link resultJsonNumber  Number
            hi def link resultJsonBool    Boolean
            hi def link resultJsonNull    Boolean
        ]==])
    end)
end

return M
