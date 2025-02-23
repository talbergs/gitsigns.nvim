local create_hunk = require("gitsigns/hunks").create_hunk
local Hunk        = require('gitsigns/hunks').Hunk

local ffi = require("ffi")

ffi.cdef[[
  typedef struct s_mmbuffer { const char *ptr; long size; } mmbuffer_t;

  typedef struct s_xpparam {
    unsigned long flags;

    // See Documentation/diff-options.txt.
    char **anchors;
    size_t anchors_nr;
  } xpparam_t;

  typedef long (__stdcall *find_func_t)(
    const char *line,
    long line_len,
    char *buffer,
    long buffer_size,
    void *priv
  );

  typedef int (__stdcall *xdl_emit_hunk_consume_func_t)(
    long start_a, long count_a, long start_b, long count_b,
    void *cb_data
  );

  typedef struct s_xdemitconf {
    long ctxlen;
    long interhunkctxlen;
    unsigned long flags;
    find_func_t find_func;
    void *find_func_priv;
    xdl_emit_hunk_consume_func_t hunk_func;
  } xdemitconf_t;

  typedef struct s_xdemitcb {
    void *priv;
    int (__stdcall *outf)(void *, mmbuffer_t *, int);
  } xdemitcb_t;

  int xdl_diff(
    mmbuffer_t *mf1,
    mmbuffer_t *mf2,
    xpparam_t const *xpp,
    xdemitconf_t const *xecfg,
    xdemitcb_t *ecb
  );
]]

local record MMBuffer
  userdata
  ptr: number
  size: number
end

local function mmbuffer(lines: {string}): MMBuffer
  local text = vim.tbl_isempty(lines) and '' or table.concat(lines, '\n')..'\n'
  return ffi.new('mmbuffer_t', text, #text)
end

local record XPParam
  userdata
  flags: number  -- unsigned long flags;

  -- char **anchors;
  -- size_t anchors_nr;
end

local function xpparam(diff_algo: string): XPParam
  local daflag = 0 -- myers

  if     diff_algo == 'minimal'   then daflag = 1
  elseif diff_algo == 'patience'  then daflag = math.floor(2^14)
  elseif diff_algo == 'histogram' then daflag = math.floor(2^15)
  end

  return ffi.new('xpparam_t', daflag)
end

local record Long
  userdata
end

local record XDEmitConf
  userdata
  hunk_func: function(Long, Long, Long, Long, any): number
end

-- local DIFF_FILLER     = 0x001   -- display filler lines
-- local DIFF_IBLANK     = 0x002   -- ignore empty lines
-- local DIFF_ICASE      = 0x004   -- ignore case
-- local DIFF_IWHITE     = 0x008   -- ignore change in white space
-- local DIFF_IWHITEALL  = 0x010   -- ignore all white space changes
-- local DIFF_IWHITEEOL  = 0x020   -- ignore change in white space at EOL
-- local DIFF_HORIZONTAL = 0x040   -- horizontal splits
-- local DIFF_VERTICAL   = 0x080   -- vertical splits
-- local DIFF_HIDDEN_OFF = 0x100   -- diffoff when hidden
-- local DIFF_INTERNAL   = 0x200   -- use internal xdiff algorithm
-- local DIFF_CLOSE_OFF  = 0x400   -- diffoff when closing window
-- local DIFF_FOLLOWWRAP = 0x800   -- follow the wrap option

local M = {}

function M.run_diff(fa: {string}, fb: {string}, diff_algo: string): {Hunk}
  local results: {Hunk} = {}

  local hunk_func = ffi.cast('xdl_emit_hunk_consume_func_t', function(
    start_a: Long, count_a: Long,
    start_b: Long, count_b: Long
  ): number
    local ca = tonumber(count_a) as integer
    local cb = tonumber(count_b) as integer
    local sa = tonumber(start_a) as integer
    local sb = tonumber(start_b) as integer

    -- Not fully sure why this offset is needed but xdiff does it too
    -- (see neovim/src/nvim/xdiff/xutils.c:356,368)
    if ca > 0 then sa = sa + 1 end
    if cb > 0 then sb = sb + 1 end

    table.insert(results, create_hunk(sa, ca, sb, cb))
    return 0
  end)

  local emitconf = ffi.new('xdemitconf_t') as XDEmitConf
  emitconf.hunk_func = hunk_func as function(Long, Long, Long, Long): number

  local res = ffi.C.xdl_diff(
    mmbuffer(fa),
    mmbuffer(fb),
    xpparam(diff_algo),
    emitconf,
    ffi.new('xdemitcb_t')
  )

  assert(res, 'DIFF bad result')

  hunk_func:free()

  for _, hunk in ipairs(results) do
    local rs, as = hunk.removed.start, hunk.added.start
    local rc, ac = hunk.removed.count, hunk.added.count
    hunk.head = ('@@ -%d%s +%d%s @@'):format(
      rs, rc > 0 and ','..rc or '',
      as, ac > 0 and ','..ac or ''
    )
    if rc > 0 then
      for i = rs, rs+rc-1 do
        table.insert(hunk.lines, '-'..(fa[i] or ''))
      end
    end
    if ac > 0 then
      for i = as, as+ac-1 do
        table.insert(hunk.lines, '+'..(fb[i] or ''))
      end
    end
  end

  return results
end

return M
