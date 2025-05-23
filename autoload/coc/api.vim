" ============================================================================
" Description: Client api used by vim8
" Author: Qiming Zhao <chemzqm@gmail.com>
" Licence: Anti 996 licence
" Last Modified: 2022-12-20
" ============================================================================
if has('nvim')
  finish
endif

scriptencoding utf-8
let s:listener_map = {}
let s:funcs = {}
let s:prop_offset = get(g:, 'coc_text_prop_offset', 1000)
let s:namespace_id = 1
let s:namespace_cache = {}
let s:max_src_id = 1000
" bufnr => max textprop id
let s:buffer_id = {}
" srcId => list of types
let s:id_types = {}
let s:tab_id = 1
let s:keymap_arguments = ['nowait', 'silent', 'script', 'expr', 'unique']
" Boolean options of vim 9.1.1134
let s:boolean_options = ['allowrevins', 'arabic', 'arabicshape', 'autochdir', 'autoindent', 'autoread', 'autoshelldir', 'autowrite', 'autowriteall', 'backup', 'balloonevalterm', 'binary', 'bomb', 'breakindent', 'buflisted', 'cdhome', 'cindent', 'compatible', 'confirm', 'copyindent', 'cursorbind', 'cursorcolumn', 'cursorline', 'delcombine', 'diff', 'digraph', 'edcompatible', 'emoji', 'endoffile', 'endofline', 'equalalways', 'errorbells', 'esckeys', 'expandtab', 'exrc', 'fileignorecase', 'fixendofline', 'foldenable', 'fsync', 'gdefault', 'hidden', 'hkmap', 'hkmapp', 'hlsearch', 'icon', 'ignorecase', 'imcmdline', 'imdisable', 'incsearch', 'infercase', 'insertmode', 'joinspaces', 'langnoremap', 'langremap', 'lazyredraw', 'linebreak', 'lisp', 'list', 'loadplugins', 'magic', 'modeline', 'modelineexpr', 'modifiable', 'modified', 'more', 'number', 'paste', 'preserveindent', 'previewwindow', 'prompt', 'readonly', 'relativenumber', 'remap', 'revins', 'rightleft', 'ruler', 'scrollbind', 'secure', 'shelltemp', 'shiftround', 'shortname', 'showcmd', 'showfulltag', 'showmatch', 'showmode', 'smartcase', 'smartindent', 'smarttab', 'smoothscroll', 'spell', 'splitbelow', 'splitright', 'startofline', 'swapfile', 'tagbsearch', 'tagrelative', 'tagstack', 'termbidi', 'termguicolors', 'terse', 'textauto', 'textmode', 'tildeop', 'timeout', 'title', 'ttimeout', 'ttybuiltin', 'ttyfast', 'undofile', 'visualbell', 'warn', 'weirdinvert', 'wildignorecase', 'wildmenu', 'winfixbuf', 'winfixheight', 'winfixwidth', 'wrap', 'wrapscan', 'write', 'writeany', 'writebackup', 'xtermcodes']

" helper {{
" Create a window with bufnr for execute win_execute
function! s:create_popup(bufnr) abort
  noa let id = popup_create(a:bufnr, {
      \ 'line': 1,
      \ 'col': &columns,
      \ 'maxwidth': 1,
      \ 'maxheight': 1,
      \ })
  call popup_hide(id)
  return id
endfunction

function! s:check_bufnr(bufnr) abort
  if a:bufnr != 0 && !bufloaded(a:bufnr)
    throw 'Invalid buffer id: '.a:bufnr
  endif
endfunction

" TextChanged and callback not fired when using channel on vim.
function! s:on_textchange(bufnr) abort
  let event = mode() ==# 'i' ? 'TextChangedI' : 'TextChanged'
  exe 'doautocmd <nomodeline> '.event.' '.bufname(a:bufnr)
  call listener_flush(a:bufnr)
endfunction

" execute command for bufnr
function! s:buf_execute(bufnr, cmds) abort
  call s:check_bufnr(a:bufnr)
  let winid = get(win_findbuf(a:bufnr), 0, -1)
  let close = 0
  if winid == -1
    let winid = s:create_popup(a:bufnr)
    let close = 1
  endif
  for cmd in a:cmds
    call win_execute(winid, cmd, 'silent')
  endfor
  if close
    noa call popup_close(winid)
  endif
endfunction

function! s:check_winid(winid) abort
  if empty(getwininfo(a:winid)) && empty(popup_getpos(a:winid))
    throw 'Invalid window id: '.a:winid
  endif
endfunction

function! s:is_popup(winid) abort
  try
    return !empty(popup_getpos(a:winid))
  catch /^Vim\%((\a\+)\)\=:E993/
    return 0
  endtry
endfunction

function! s:tabid_nr(tid) abort
  for nr in range(1, tabpagenr('$'))
    if gettabvar(nr, '__tid', v:null) is a:tid
      return nr
    endif
  endfor
  throw 'Invalid tabpage id: '.a:tid
endfunction

function! s:tabnr_id(nr) abort
  let tid = gettabvar(a:nr, '__tid', -1)
  if tid == -1
    let tid = s:tab_id
    call settabvar(a:nr, '__tid', tid)
    let s:tab_id = s:tab_id + 1
  endif
  return tid
endfunction

function! s:win_execute(winid, cmd, ...) abort
  let ref = get(a:000, 0, v:null)
  let cmd = ref is v:null ? a:cmd : 'let ref["out"] = ' . a:cmd
  call win_execute(a:winid, cmd)
endfunction

function! s:win_tabnr(winid) abort
  let ref = {}
  call win_execute(a:winid, 'let ref["out"] = tabpagenr()')
  let tabnr = get(ref, 'out', -1)
  if tabnr == -1
    throw 'Invalid window id: '.a:winid
  endif
  return tabnr
endfunction

function! s:buf_line_count(bufnr) abort
  if a:bufnr == 0
    return line('$')
  endif
  let info = getbufinfo(a:bufnr)
  if empty(info)
    throw "Invalid buffer id: ".a:bufnr
  endif
  if info[0]['loaded'] == 0
    return 0
  endif
  return info[0]['linecount']
endfunction

function! s:execute(cmd)
  if a:cmd =~# '^echo'
    execute a:cmd
  else
    silent! execute a:cmd
  endif
endfunction

function s:inspect_type(v) abort
  let types = ['Number', 'String', 'Funcref', 'List', 'Dictionary', 'Float', 'Boolean', 'Null']
  return get(types, type(a:v), 'Unknown')
endfunction

function! s:escape_space(text) abort
  return substitute(a:text, ' ', '<space>', 'g')
endfunction

function! s:create_mode_prefix(mode, opts) abort
  if a:mode ==# '!'
    return 'map!'
  endif
  return get(a:opts, 'noremap', 0) ?  a:mode . 'noremap' : a:mode . 'map'
endfunction

function! s:create_arguments(opts) abort
  let arguments = ''
  for key in keys(a:opts)
    if a:opts[key] && index(s:keymap_arguments, key) != -1
      let arguments .= '<'.key.'>'
    endif
  endfor
  return arguments
endfunction
" }}"

" nvim client methods {{
function! s:funcs.set_current_dir(dir) abort
  execute 'cd '.fnameescape(a:dir)
  return v:null
endfunction

function! s:funcs.set_var(name, value) abort
  execute 'let g:'.a:name.'= a:value'
  return v:null
endfunction

function! s:funcs.del_var(name) abort
  if !has_key(g:, a:name)
    throw 'Key not found: '.a:name
  endif
  execute 'unlet g:'.a:name
  return v:null
endfunction

function! s:funcs.set_option(name, value) abort
  execute 'let &'.a:name.' = a:value'
  return v:null
endfunction

function! s:funcs.get_option(name)
  return eval('&'.a:name)
endfunction

function! s:funcs.set_current_buf(bufnr) abort
  call s:check_bufnr(a:bufnr)
  execute 'buffer '.a:bufnr
  return v:null
endfunction

function! s:funcs.set_current_win(winid) abort
  call s:win_tabnr(a:winid)
  call win_gotoid(a:winid)
  return v:null
endfunction

function! s:funcs.set_current_tabpage(tid) abort
  let nr = s:tabid_nr(a:tid)
  execute 'normal! '.nr.'gt'
  return v:null
endfunction

function! s:funcs.list_wins() abort
  return map(getwininfo(), 'v:val["winid"]')
endfunction

function! s:funcs.call_atomic(calls)
  let results = []
  for i in range(len(a:calls))
    let [key, arglist] = a:calls[i]
    let name = key[5:]
    try
      call add(results, call(s:funcs[name], arglist))
    catch /.*/
      return [results, [i, "VimException(".s:inspect_type(v:exception).")", v:exception . ' on function "'.name.'"']]
    endtry
  endfor
  return [results, v:null]
endfunction

function! s:funcs.set_client_info(...) abort
  " not supported
  return v:null
endfunction

function! s:funcs.subscribe(...) abort
  " not supported
  return v:null
endfunction

function! s:funcs.unsubscribe(...) abort
  " not supported
  return v:null
endfunction

function! s:funcs.call_function(method, args) abort
  return call(a:method, a:args)
endfunction

function! s:funcs.call_dict_function(dict, method, args) abort
  if type(a:dict) == v:t_string
    return call(a:method, a:args, eval(a:dict))
  endif
  return call(a:method, a:args, a:dict)
endfunction

function! s:funcs.command(command) abort
  " command that could cause cursor vanish
  if a:command =~# '^echo' || a:command =~# '^redraw' || a:command =~# '^sign place'
    call timer_start(0, {-> s:execute(a:command)})
  else
    execute a:command
    let err = get(g:, 'errmsg', '')
    " get error from python script run.
    if !empty(err)
      unlet g:errmsg
      throw 'Command error '.err
    endif
  endif
endfunction

function! s:funcs.eval(expr) abort
  return eval(a:expr)
endfunction

function! s:funcs.get_api_info()
  let names = coc#api#func_names()
  let channel = coc#rpc#get_channel()
  if empty(channel)
    throw 'Unable to get channel'
  endif
  return [ch_info(channel)['id'], {'functions': map(names, '{"name": "nvim_".v:val}')}]
endfunction

function! s:funcs.list_bufs()
  return map(getbufinfo(), 'v:val["bufnr"]')
endfunction

function! s:funcs.feedkeys(keys, mode, escape_csi)
  call feedkeys(a:keys, a:mode)
  return v:null
endfunction

function! s:funcs.list_runtime_paths()
  return globpath(&runtimepath, '', 0, 1)
endfunction

function! s:funcs.command_output(cmd)
  return execute(a:cmd)
endfunction

function! s:funcs.exec(code, output) abort
  let cmds = split(a:code, '\n')
  if a:output
    return substitute(execute(cmds, 'silent!'), '^\n', '', '')
  endif
  call execute(cmds)
  return v:null
endfunction

" Queues raw user-input, <" is special. To input a literal "<", send <LT>.
function! s:funcs.input(keys) abort
  let escaped = substitute(a:keys, '<', '\\<', 'g')
  call feedkeys(eval('"'.escaped.'"'), 't')
  return v:null
endfunction

function! s:funcs.create_buf(listed, scratch) abort
  let bufnr = bufadd('')
  call setbufvar(bufnr, '&buflisted', a:listed ? 1 : 0)
  if a:scratch
    call setbufvar(bufnr, '&modeline', 0)
    call setbufvar(bufnr, '&buftype', 'nofile')
    call setbufvar(bufnr, '&swapfile', 0)
  endif
  call bufload(bufnr)
  return bufnr
endfunction

function! s:funcs.get_current_line()
  return getline('.')
endfunction

function! s:funcs.set_current_line(line)
  call setline('.', a:line)
  call s:on_textchange(bufnr('%'))
  return v:null
endfunction

function! s:funcs.del_current_line()
  call deletebufline('%', line('.'))
  call s:on_textchange(bufnr('%'))
  return v:null
endfunction

function! s:funcs.get_var(var)
  return get(g:, a:var, v:null)
endfunction

function! s:funcs.get_vvar(var)
  return get(v:, a:var, v:null)
endfunction

function! s:funcs.get_current_buf()
  return bufnr('%')
endfunction

function! s:funcs.get_current_win()
  return win_getid()
endfunction

function! s:funcs.get_current_tabpage()
  return s:tabnr_id(tabpagenr())
endfunction

function! s:funcs.list_tabpages()
  let ids = []
  for nr in range(1, tabpagenr('$'))
    call add(ids, s:tabnr_id(nr))
  endfor
  return ids
endfunction

function! s:funcs.get_mode()
  let m = mode()
  return {'blocking': m ==# 'r' ? v:true : v:false, 'mode': m}
endfunction

function! s:funcs.strwidth(str)
  return strwidth(a:str)
endfunction

function! s:funcs.out_write(str)
  echon a:str
  call timer_start(0, {-> s:execute('redraw')})
endfunction

function! s:funcs.err_write(str)
  "echoerr a:str
endfunction

function! s:funcs.err_writeln(str)
  echohl ErrorMsg
  echom a:str
  echohl None
  call timer_start(0, {-> s:execute('redraw')})
endfunction

function! s:funcs.create_namespace(name) abort
  if empty(a:name)
    let id = s:namespace_id
    let s:namespace_id = s:namespace_id + 1
    return id
  endif
  let id = get(s:namespace_cache, a:name, 0)
  if !id
    let id = s:namespace_id
    let s:namespace_id = s:namespace_id + 1
    let s:namespace_cache[a:name] = id
  endif
  return id
endfunction

function! s:funcs.set_keymap(mode, lhs, rhs, opts) abort
  let modekey = s:create_mode_prefix(a:mode, a:opts)
  let arguments = s:create_arguments(a:opts)
  let lhs = s:escape_space(a:lhs)
  let rhs = empty(a:rhs) ? '<Nop>' : s:escape_space(a:rhs)
  let cmd = modekey . ' ' . arguments .' '.lhs. ' '.rhs
  execute cmd
  return v:null
endfunction

function! s:funcs.del_keymap(mode, lhs) abort
  let lhs = substitute(a:lhs, ' ', '<space>', 'g')
  execute 'silent '.a:mode.'unmap '.lhs
  return v:null
endfunction

function! s:funcs.set_option_value(name, value, opts) abort
  let l:win = get(a:opts, 'win', 0)
  let l:buf = get(a:opts, 'buf', 0)
  if has_key(a:opts, 'scope') && has_key(a:opts, 'buf')
    throw "Can't use both scope and buf"
  endif
  let l:scope = get(a:opts, 'scope', 'global')
  call s:check_option_args(l:scope, l:win, l:buf)
  if l:buf != 0
    call s:funcs.buf_set_option(l:buf, a:name, a:value)
  elseif l:win != 0
    call s:funcs.win_set_option(l:win, a:name, a:value)
  else
    if l:scope ==# 'global'
      execute 'let &'.a:name.' = a:value'
    else
      call s:funcs.win_set_option(win_getid(), a:name, a:value)
      call s:funcs.buf_set_option(bufnr('%'), a:name, a:value)
    endif
  endif
  return v:null
endfunction

function! s:funcs.get_option_value(name, opts) abort
  let l:win = get(a:opts, 'win', 0)
  let l:buf = get(a:opts, 'buf', 0)
  if has_key(a:opts, 'scope') && has_key(a:opts, 'buf')
    throw "Can't use both scope and buf"
  endif
  let l:scope = get(a:opts, 'scope', 'global')
  call s:check_option_args(l:scope, l:win, l:buf)
  let l:result = v:null
  " return eval('&'.a:name)
  if l:buf != 0
    let l:result = getbufvar(l:buf, '&'.a:name)
  elseif l:win != 0
    let l:result = s:funcs.win_get_option(l:win, a:name)
  else
    if l:scope ==# 'global'
      let l:result = eval('&'.a:name)
    else
      let l:result = gettabwinvar(tabpagenr(), 0, '&'.a:name, get(a:, 1, v:null))
      if l:result is v:null
        let l:result = getbufvar(bufnr('%'), '&'.a:name)
      endif
    endif
  endif
  if index(s:boolean_options, a:name) != -1
    return l:result == 0 ? v:false : v:true
  endif
  return l:result
endfunction

function! s:check_option_args(scope, win, buf) abort
  if a:scope !=# 'global' && a:scope !=# 'local'
    throw "Invalid 'scope': expected 'local' or 'global'"
  endif
  if a:win && empty(getwininfo(a:win)) && empty(popup_getpos(a:win))
    throw "Invalid window id: ".a:win
  endif
  if a:buf && !bufexists(a:buf)
    throw "Invalid buffer id: ".a:buf
  endif
endfunction
" }}

" buffer methods {{
function! s:funcs.buf_set_option(bufnr, name, val)
  let val = a:val
  if val is v:true
    let val = 1
  elseif val is v:false
    let val = 0
  endif
  call setbufvar(a:bufnr, '&'.a:name, val)
  return v:null
endfunction

function! s:funcs.buf_get_option(bufnr, name)
  call s:check_bufnr(a:bufnr)
  return getbufvar(a:bufnr, '&'.a:name)
endfunction

function! s:funcs.buf_get_changedtick(bufnr)
  return getbufvar(a:bufnr, 'changedtick')
endfunction

function! s:funcs.buf_is_valid(bufnr)
  return bufexists(a:bufnr) ? v:true : v:false
endfunction

function! s:funcs.buf_is_loaded(bufnr)
  return bufloaded(a:bufnr) ? v:true : v:false
endfunction

function! s:funcs.buf_get_mark(bufnr, name)
  if a:bufnr != 0 && a:bufnr != bufnr('%')
    throw 'buf_get_mark support current buffer only'
  endif
  return [line("'" . a:name), col("'" . a:name) - 1]
endfunction

def s:funcs.buf_add_highlight(bufnr: number, srcId: number, hlGroup: string, line: number, colStart: number, colEnd: number, propTypeOpts: dict<any> = {}): any
  var sourceId: number
  if srcId == 0
    sourceId = s:max_src_id + 1
    s:max_src_id = sourceId
  else
    sourceId = srcId
  endif
  const bufferNumber: number = bufnr == 0 ? bufnr('%') : bufnr
  call coc#api#funcs_buf_add_highlight(bufferNumber, sourceId, hlGroup, line, colStart, colEnd, propTypeOpts)
  return sourceId
enddef

" To be called directly for better performance
" 0 based line, colStart, colEnd, see `:h prop_type_add` for propTypeOpts
def coc#api#funcs_buf_add_highlight(bufnr: number, srcId: number, hlGroup: string, line: number, colStart: number, colEnd: number, propTypeOpts: dict<any> = {}): void
  const columnEnd: number = colEnd == -1 ? strlen(get(getbufline(bufnr, line + 1), 0, '')) + 1 : colEnd + 1
  if columnEnd < colStart + 1
    return
  endif
  const propType: string = coc#api#create_type(srcId, hlGroup, propTypeOpts)
  const propId: number = s:generate_id(bufnr)
  try
    prop_add(line + 1, colStart + 1, {'bufnr': bufnr, 'type': propType, 'id': propId, 'end_col': columnEnd})
  catch /^Vim\%((\a\+)\)\=:\(E967\|E964\)/
    # ignore 967
  endtry
enddef

function! s:funcs.buf_clear_namespace(bufnr, srcId, startLine, endLine) abort
  let bufnr = a:bufnr == 0 ? bufnr('%') : a:bufnr
  let start = a:startLine + 1
  let end = a:endLine == -1 ? s:buf_line_count(bufnr) : a:endLine
  if a:srcId == -1
    if has_key(s:buffer_id, a:bufnr)
      unlet s:buffer_id[a:bufnr]
    endif
    call prop_clear(start, end, {'bufnr' : bufnr})
  else
    let types = get(s:id_types, a:srcId, [])
    try
      call prop_remove({'bufnr': bufnr, 'all': 1, 'types': types}, start, end)
    catch /^Vim\%((\a\+)\)\=:E968/
      " ignore 968
    endtry
  endif
  return v:null
endfunction

function! s:funcs.buf_line_count(bufnr) abort
  return s:buf_line_count(a:bufnr)
endfunction

function! s:funcs.buf_attach(...)
  let bufnr = get(a:, 1, 0)
  " listener not removed on e!
  let id = get(s:listener_map, bufnr, 0)
  if id
    call listener_remove(id)
  endif
  let result = listener_add('s:on_buf_change', bufnr)
  if result
    let s:listener_map[bufnr] = result
    return v:true
  endif
  return v:false
endfunction

function! s:on_buf_change(bufnr, start, end, added, changes) abort
  let result = []
  for item in a:changes
    let start = item['lnum'] - 1
    " Delete lines
    if item['added'] < 0
      " include start line, which needed for undo
      let lines = getbufline(a:bufnr, item['lnum'])
      call add(result, [start, 0 - item['added'] + 1, lines])
    " Add lines
    elseif item['added'] > 0
      let lines = getbufline(a:bufnr, item['lnum'], item['lnum'] + item['added'])
      call add(result, [start, 1, lines])
    " Change lines
    else
      let lines = getbufline(a:bufnr, item['lnum'], item['end'] - 1)
      call add(result, [start, item['end'] - item['lnum'], lines])
    endif
  endfor
  call coc#rpc#notify('vim_buf_change_event', [a:bufnr, getbufvar(a:bufnr, 'changedtick'), result])
endfunction

function! s:funcs.buf_detach()
  " not supported
  return 1
endfunction

function! s:funcs.buf_get_lines(bufnr, start, end, strict) abort
  call s:check_bufnr(a:bufnr)
  let len = s:buf_line_count(a:bufnr)
  let start = a:start < 0 ? len + a:start + 2 : a:start + 1
  let end = a:end < 0 ? len + a:end + 1 : a:end
  if a:strict && end > len
    throw 'Index out of bounds '. end
  endif
  return getbufline(a:bufnr, start, end)
endfunction

function! s:funcs.buf_set_lines(bufnr, start, end, strict, ...) abort
  call s:check_bufnr(a:bufnr)
  let bufnr = a:bufnr == 0 ? bufnr('%') : a:bufnr
  let len = s:buf_line_count(bufnr)
  let startLnum = a:start < 0 ? len + a:start + 2 : a:start + 1
  let endLnum = a:end < 0 ? len + a:end + 1 : a:end
  if endLnum > len
    if a:strict
      throw 'Index out of bounds '. end
    else
      let endLnum = len
    endif
  endif
  let delCount = endLnum - (startLnum - 1)
  let view = bufnr == bufnr('%') ? winsaveview() : v:null
  let replacement = get(a:, 1, [])
  if delCount == len(replacement)
    call setbufline(bufnr, startLnum, replacement)
  else
    if len(replacement)
      call appendbufline(bufnr, startLnum - 1, replacement)
    endif
    if delCount
      let start = startLnum + len(replacement)
      silent call deletebufline(bufnr, start, start + delCount - 1)
    endif
  endif
  if view isnot v:null
    call winrestview(view)
  endif
  call s:on_textchange(a:bufnr)
  return v:null
endfunction

function! s:funcs.buf_set_name(bufnr, name) abort
  call s:check_bufnr(a:bufnr)
  call s:buf_execute(a:bufnr, [
      \ 'noa 0f',
      \ 'file '.fnameescape(a:name)
      \ ])
  return v:null
endfunction

function! s:funcs.buf_get_name(bufnr)
  call s:check_bufnr(a:bufnr)
  return bufname(a:bufnr)
endfunction

function! s:funcs.buf_get_var(bufnr, name)
  call s:check_bufnr(a:bufnr)
  if !has_key(getbufvar(a:bufnr, ''), a:name)
    throw 'Key not found: '.a:name
  endif
  return getbufvar(a:bufnr, a:name)
endfunction

function! s:funcs.buf_set_var(bufnr, name, val)
  call s:check_bufnr(a:bufnr)
  call setbufvar(a:bufnr, a:name, a:val)
  return v:null
endfunction

function! s:funcs.buf_del_var(bufnr, name)
  call s:check_bufnr(a:bufnr)
  let bufvars = getbufvar(a:bufnr, '')
  call remove(bufvars, a:name)
  return v:null
endfunction

function! s:funcs.buf_set_keymap(bufnr, mode, lhs, rhs, opts) abort
  let modekey = s:create_mode_prefix(a:mode, a:opts)
  let arguments = s:create_arguments(a:opts)
  let lhs = s:escape_space(a:lhs)
  let rhs = empty(a:rhs) ? '<Nop>' : s:escape_space(a:rhs)
  let cmd = modekey . ' ' . arguments .'<buffer> '.lhs. ' '.rhs
  if bufnr('%') == a:bufnr || a:bufnr == 0
    execute cmd
  else
    call s:buf_execute(a:bufnr, [cmd])
  endif
  return v:null
endfunction

function! s:funcs.buf_del_keymap(bufnr, mode, lhs) abort
  let lhs = substitute(a:lhs, ' ', '<space>', 'g')
  let cmd = 'silent '.a:mode.'unmap <buffer> '.lhs
  if bufnr('%') == a:bufnr || a:bufnr == 0
    execute cmd
  else
    call s:buf_execute(a:bufnr, [cmd])
  endif
  return v:null
endfunction
" }}

" window methods {{
function! s:funcs.win_get_buf(winid)
  call s:check_winid(a:winid)
  return winbufnr(a:winid)
endfunction

function! s:funcs.win_set_buf(winid, bufnr) abort
  call s:check_winid(a:winid)
  call s:check_bufnr(a:bufnr)
  call s:win_execute(a:winid, 'buffer '.a:bufnr)
  return v:null
endfunction

function! s:funcs.win_get_position(winid) abort
  let [row, col] = win_screenpos(a:winid)
  if row == 0 && col == 0
    throw 'Invalid window '.a:winid
  endif
  return [row - 1, col - 1]
endfunction

function! s:funcs.win_set_height(winid, height) abort
  call s:check_winid(a:winid)
  if s:is_popup(a:winid)
    call popup_move(a:winid, {'maxheight': a:height, 'minheight': a:height})
  else
    call s:win_execute(a:winid, 'resize '.a:height)
  endif
  return v:null
endfunction

function! s:funcs.win_get_height(winid) abort
  call s:check_winid(a:winid)
  if s:is_popup(a:winid)
    return popup_getpos(a:winid)['height']
  endif
  return winheight(a:winid)
endfunction

function! s:funcs.win_set_width(winid, width) abort
  call s:check_winid(a:winid)
  if s:is_popup(a:winid)
    call popup_move(a:winid, {'maxwidth': a:width, 'minwidth': a:width})
  else
    call s:win_execute(a:winid, 'vertical resize '.a:width)
  endif
  return v:null
endfunction

function! s:funcs.win_get_width(winid) abort
  call s:check_winid(a:winid)
  if s:is_popup(a:winid)
    return popup_getpos(a:winid)['width']
  endif
  return winwidth(a:winid)
endfunction

function! s:funcs.win_set_cursor(winid, pos) abort
  call s:check_winid(a:winid)
  let [line, col] = a:pos
  call s:win_execute(a:winid, 'call cursor('.line.','.(col + 1).')')
  return v:null
endfunction

function! s:funcs.win_get_cursor(winid) abort
  call s:check_winid(a:winid)
  let ref = {}
  call s:win_execute(a:winid, "[line('.'), col('.')-1]", ref)
  return get(ref, 'out', [1, 0])
endfunction

function! s:funcs.win_set_option(winid, name, value) abort
  let tabnr = s:win_tabnr(a:winid)
  let val = a:value
  if val is v:true
    let val = 1
  elseif val is v:false
    let val = 0
  endif
  call settabwinvar(tabnr, a:winid, '&'.a:name, val)
  return v:null
endfunction

function! s:funcs.win_get_option(winid, name, ...) abort
  let tabnr = s:win_tabnr(a:winid)
  let result = gettabwinvar(tabnr, a:winid, '&'.a:name, get(a:, 1, v:null))
  if result is v:null
    throw "Invalid option name: '".a:name."'"
  endif
  return result
endfunction

function! s:funcs.win_get_var(winid, name, ...) abort
  let tabnr = s:win_tabnr(a:winid)
  return gettabwinvar(tabnr, a:winid, a:name, get(a:, 1, v:null))
endfunction

function! s:funcs.win_set_var(winid, name, value) abort
  let tabnr = s:win_tabnr(a:winid)
  call settabwinvar(tabnr, a:winid, a:name, a:value)
  return v:null
endfunction

function! s:funcs.win_del_var(winid, name) abort
  call s:check_winid(a:winid)
  call win_execute(a:winid, 'unlet! w:'.a:name)
  return v:null
endfunction

function! s:funcs.win_is_valid(winid) abort
  let invalid = empty(getwininfo(a:winid)) && empty(popup_getpos(a:winid))
  return invalid ? v:false : v:true
endfunction

" Not work for popup
function! s:funcs.win_get_number(winid) abort
  if s:is_popup(a:winid)
    return 0
  endif
  let info = getwininfo(a:winid)
  if empty(info)
    throw 'Invalid window id '.a:winid
  endif
  return info[0]['winnr']
endfunction

function! s:funcs.win_get_tabpage(winid) abort
  let nr = s:win_tabnr(a:winid)
  return s:tabnr_id(nr)
endfunction

function! s:funcs.win_close(winid, ...) abort
  call s:check_winid(a:winid)
  let force = get(a:, 1, 0)
  if s:is_popup(a:winid)
    call popup_close(a:winid)
  else
    call s:win_execute(a:winid, 'close'.(force ? '!' : ''))
  endif
  return v:null
endfunction
" }}

" tabpage methods {{
function! s:funcs.tabpage_get_number(tid)
  return s:tabid_nr(a:tid)
endfunction

function! s:funcs.tabpage_list_wins(tid)
  let nr = s:tabid_nr(a:tid)
  return gettabinfo(nr)[0]['windows']
endfunction

function! s:funcs.tabpage_get_var(tid, name)
  let nr = s:tabid_nr(a:tid)
  return gettabvar(nr, a:name, v:null)
endfunction

function! s:funcs.tabpage_set_var(tid, name, value)
  let nr = s:tabid_nr(a:tid)
  call settabvar(nr, a:name, a:value)
  return v:null
endfunction

function! s:funcs.tabpage_del_var(tid, name)
  let nr = s:tabid_nr(a:tid)
  call settabvar(nr, a:name, v:null)
  return v:null
endfunction

function! s:funcs.tabpage_is_valid(tid)
  for nr in range(1, tabpagenr('$'))
    if gettabvar(nr, '__tid', -1) == a:tid
      return v:true
    endif
  endfor
  return v:false
endfunction

function! s:funcs.tabpage_get_win(tid)
  let nr = s:tabid_nr(a:tid)
  return win_getid(tabpagewinnr(nr), nr)
endfunction
" }}

def coc#api#get_types(srcId: number): list<string>
  return get(s:id_types, srcId, [])
enddef

def coc#api#create_type(src_id: number, hl_group: string, opts: dict<any>): string
  const type: string = hl_group .. '_' .. string(src_id)
  final types: list<string> = get(s:id_types, src_id, [])
  if index(types, type) == -1
    add(types, type)
    s:id_types[src_id] = types
    if empty(prop_type_get(type))
      final type_option: dict<any> = {'highlight': hl_group}
      const hl_mode: string = get(opts, 'hl_mode', 'combine')
      if hl_mode !=# 'combine'
        type_option['override'] = 1
        type_option['combine'] = 0
      endif
      # vim not throw for unknown properties
      prop_type_add(type, extend(type_option, opts))
    endif
  endif
  return type
enddef

def s:generate_id(bufnr: number): number
  const max: number = get(s:buffer_id, bufnr, s:prop_offset)
  const id: number = max + 1
  s:buffer_id[bufnr] = id
  return id
enddef

function! coc#api#func_names() abort
  return keys(s:funcs)
endfunction

function! coc#api#call(method, args) abort
  let err = v:null
  let res = v:null
  try
    let tick = b:changedtick
    let res = call(s:funcs[a:method], a:args)
    if b:changedtick != tick
      call listener_flush()
    endif
  catch /.*/
    let err = v:exception .' on api "'.a:method.'" '.json_encode(a:args)
  endtry
  return [err, res]
endfunction

function! coc#api#exec(method, args) abort
  return call(s:funcs[a:method], a:args)
endfunction

function! coc#api#notify(method, args) abort
  try
    let tick = b:changedtick
    " vim throw error with return when vim9 function has no return value.
    if a:method ==# 'call_function'
      call call(a:args[0], a:args[1])
    elseif a:method ==# 'call_dict_function'
      if type(a:args[0]) == v:t_string
        call call(a:args[1], a:args[2], eval(a:args[0]))
      else
        call call(a:args[1], a:args[2], a:args[0])
      endif
    else
      call call(s:funcs[a:method], a:args)
    endif
    if b:changedtick != tick
      call listener_flush()
    endif
  catch /.*/
    call coc#rpc#notify('nvim_error_event', [0, v:exception.' on api "'.a:method.'" '.json_encode(a:args)])
  endtry
endfunction

" create id for all tabpages
function! coc#api#tabpage_ids() abort
  for nr in range(1, tabpagenr('$'))
    if gettabvar(nr, '__tid', -1) == -1
      call settabvar(nr, '__tid', s:tab_id)
      let s:tab_id = s:tab_id + 1
    endif
  endfor
endfunction

function! coc#api#get_tabid(nr) abort
  return s:tabnr_id(a:nr)
endfunction

defcompile
" vim: set sw=2 ts=2 sts=2 et tw=78 foldmarker={{,}} foldmethod=marker foldlevel=0:
