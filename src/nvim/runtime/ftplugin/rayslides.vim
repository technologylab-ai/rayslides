" Vim filetype settings for Rayslides decks.
if exists('b:did_ftplugin')
  finish
endif
let b:did_ftplugin = 1

setlocal comments=b:#
setlocal commentstring=#\ %s

let b:undo_ftplugin = 'setlocal comments< commentstring<'
