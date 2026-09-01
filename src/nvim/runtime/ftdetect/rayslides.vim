" Vim filetype detection for Rayslides decks. Neovim's built-in detector uses
" .sld for another format, so this bundled runtime must intentionally override
" that generic association when it is on the host application's runtimepath.
autocmd BufRead,BufNewFile *.sld setlocal filetype=rayslides
