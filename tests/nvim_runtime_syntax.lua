-- Headless assertions for the bundled Rayslides Vim runtime.
-- Run from the repository root with:
--   nvim --clean --headless --cmd 'set runtimepath^=src/nvim/runtime' \
--     -l tests/nvim_runtime_syntax.lua

-- --clean enables detection before the test runtime is prepended. Reload the
-- detector set so this exercises the bundled ftdetect file itself.
vim.cmd('filetype off')
vim.cmd('filetype on')
vim.cmd('syntax on')

local filename = vim.fn.tempname() .. '.sld'
vim.cmd('edit ' .. vim.fn.fnameescape(filename))
assert(vim.bo.filetype == 'rayslides', 'expected *.sld filetype detection')

local lines = {
  '# TODO source comment',
  '@fontsize=34',
  '@pushgroup feature',
  '@box id=hero x=-12.5 w=1280 color=#61dafbff visible=true img=assets/hero.png text=**Hello** color=prose',
  '@endgroup',
  '@popgroup feature id=intro',
  '@state(morph) label=takeover duration=0.8 ease=spring',
  '@set intro.hero x=0 fit=cover',
  '@let accent=#f7a41dff',
  '@box color=$accent$ video_size=1920x1080 autoplay',
  '- _italic_ and ~~underlined~~ and <#ff0000ff>red</>',
  '@notes',
  '# private note, not a source comment',
  '@slide is private prose here',
  '@endnotes',
  '@definitely_unknown typo=value',
}
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.cmd('syntax sync fromstart')

local function group_at(line, needle, offset)
  local start = assert(lines[line]:find(needle, 1, true), ('missing %q on line %d'):format(needle, line))
  local column = start + (offset or 0)
  local id = vim.fn.synID(line, column, true)
  return vim.fn.synIDattr(id, 'name')
end

local function expect(line, needle, expected, offset)
  local actual = group_at(line, needle, offset)
  assert(actual == expected,
    ('line %d %q: expected %s, got %s'):format(line, needle, expected, actual))
end

expect(1, '# TODO', 'rayslidesComment')
expect(1, 'TODO', 'rayslidesTodo')
expect(2, '@fontsize', 'rayslidesDirective')
expect(2, '34', 'rayslidesNumber')
expect(3, 'feature', 'rayslidesDefinition')
expect(4, 'id=', 'rayslidesAttribute')
expect(4, 'hero', 'rayslidesDefinition')
expect(4, '-12.5', 'rayslidesNumber')
expect(4, '#61dafbff', 'rayslidesColor')
expect(4, 'true', 'rayslidesBoolean')
expect(4, 'assets/hero.png', 'rayslidesString')
expect(4, '**', 'rayslidesMarkup')
expect(4, 'Hello', 'rayslidesBold')
expect(4, 'color=prose', 'rayslidesTextValue')
expect(6, 'feature', 'rayslidesReference')
expect(6, 'intro', 'rayslidesDefinition')
expect(7, 'morph', 'rayslidesEnum')
expect(7, 'takeover', 'rayslidesDefinition')
expect(7, 'spring', 'rayslidesEnum')
expect(8, 'intro.hero', 'rayslidesReference')
expect(8, 'cover', 'rayslidesEnum')
expect(9, 'accent', 'rayslidesDefinition')
expect(9, '#f7a41dff', 'rayslidesColor')
expect(10, '$accent$', 'rayslidesVariable')
expect(10, '1920x1080', 'rayslidesDimension')
expect(10, 'autoplay', 'rayslidesBoolean')
expect(11, '-', 'rayslidesBullet')
expect(11, 'italic', 'rayslidesItalic')
expect(11, 'underlined', 'rayslidesUnderline')
expect(11, '<#ff0000ff>', 'rayslidesColor')
expect(13, '# private', 'rayslidesNotes')
expect(14, '@slide', 'rayslidesNotes')
expect(16, '@definitely_unknown', 'rayslidesUnknownDirective')
expect(16, 'typo=', 'rayslidesUnknownAttribute')

vim.cmd('bwipeout!')

-- Catch syntax-engine errors and pathological patterns against every real
-- repository deck, not only the focused group assertions above.
local decks = vim.fn.glob('testslides/**/*.sld', false, true)
vim.list_extend(decks, vim.fn.glob('src/starters/*.sld', false, true))
for _, deck in ipairs(decks) do
  vim.cmd('edit ' .. vim.fn.fnameescape(deck))
  assert(vim.bo.filetype == 'rayslides', ('expected rayslides filetype for %s'):format(deck))
  vim.cmd('syntax sync fromstart')
  vim.cmd('bwipeout!')
end

-- The embedder uses this path for unnamed scratch buffers instead of relying
-- on the filename detector.
vim.cmd('enew')
vim.cmd('setfiletype rayslides')
assert(vim.b.current_syntax == 'rayslides', 'expected manual filetype to load syntax')
vim.cmd('bwipeout!')

print(('Rayslides Neovim runtime syntax checks passed (%d real decks)'):format(#decks))
