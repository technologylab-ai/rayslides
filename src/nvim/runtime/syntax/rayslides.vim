" Vim syntax file
" Language: Rayslides slideshow source
" Maintainer: Rayslides contributors

if exists('b:current_syntax')
  finish
endif

syntax case match

" Comments only have source meaning at column one. Inside @notes, a leading
" hash is ordinary private prose and is handled by rayslidesNotes below.
syntax keyword rayslidesTodo TODO FIXME XXX NOTE contained
syntax match rayslidesComment /^#.*$/ contains=rayslidesTodo,@Spell

" All ordinary prose belongs to the most recently opened item. Keeping this
" as a transparent match lets the inline formatting groups carry the color
" scheme while leaving unformatted prose readable as normal buffer text.
syntax match rayslidesBodyLine /^\%([@#]\)\@!.\+$/ transparent contains=@rayslidesInline,rayslidesBullet,rayslidesBlankLine,@Spell
syntax match rayslidesBullet /^\s*-\ze/ contained
syntax match rayslidesBlankLine /^\s*[_`]\s*$/ contained

" A directive consumes one physical line. text= is special: the parser gives
" its complete remainder to the item, so rayslidesTextValue deliberately
" prevents attribute-looking prose after text= from being recolored.
syntax match rayslidesDirectiveLine /^@.*$/ transparent contains=rayslidesUnknownDirective,rayslidesDirective,rayslidesDelimiter,rayslidesUnknownAttribute,rayslidesAttribute,rayslidesOperator,rayslidesNumber,rayslidesDimension,rayslidesColor,rayslidesBoolean,rayslidesEnum,rayslidesString,rayslidesTextValue,rayslidesDefinition,rayslidesReference,rayslidesVariable

" Unknown names are shown as errors. The known directive and attribute
" matches below are defined later and therefore take precedence at the same
" byte. This catches typos that the permissive item parser might otherwise
" ignore silently.
syntax match rayslidesUnknownDirective /@[A-Za-z_][A-Za-z0-9_-]*/ contained
syntax match rayslidesUnknownAttribute /\<[A-Za-z_][A-Za-z0-9_]*\ze=/ contained

syntax match rayslidesDirective /@\%(slide\|box\|bg\|line\|push\|pop\|pushslide\|popslide\|pushgroup\|popgroup\|endgroup\|notes\|endnotes\|crowd\|set\|show\|hide\|anim\|state\|let\|fontsize\|font\|font_bold\|font_italic\|font_bold_italic\|font_extra\|underline_width\|line_height\|color\|bullet_color\|bullet_symbol\|transition\|transition_duration\|transition_ease\)\>/ contained

syntax match rayslidesAttribute /\<\%(id\|x\|y\|w\|h\|fontsize\|radius\|stroke_width\|direction\|arrow\|rotation\|align\|valign\|color\|bg\|opacity\|visible\|locked\|shadow\|shadow_offset\|shadow_x\|shadow_y\)\ze=/ contained
syntax match rayslidesAttribute /\<\%(bullet_color\|bullet_symbol\|underline_width\|line_height\|img\|vid\|cam\|video_size\|cam_format\|poster_image\|autoplay\|loop\|poster\|volume\|muted\|fit\|focus_x\|focus_y\|scale\|ratio\)\ze=/ contained
syntax match rayslidesAttribute /\<\%(open\|anim\|effect\|by\|after\|delay\|order\|ease\|label\|transition\|duration\|text\)\ze=/ contained

syntax match rayslidesOperator /=/ contained
syntax match rayslidesDelimiter /[()]/ contained

" Stable definitions and references are first-class in the format. Reusable
" group instance members use a dotted target such as intro.title.
syntax match rayslidesDefinition /\%(^@\%(push\|pushslide\|pushgroup\)\s\+\)\@<=[A-Za-z_][A-Za-z0-9_-]*/ contained
syntax match rayslidesDefinition /\%(\<\%(id\|label\)=\)\@<=[A-Za-z_][A-Za-z0-9_-]*/ contained
syntax match rayslidesDefinition /\%(^@let\s\+\)\@<=[A-Za-z_][A-Za-z0-9_-]*\ze\s*=/ contained
syntax match rayslidesReference /\%(^@\%(pop\|popslide\|popgroup\|set\|show\|hide\)\s\+\)\@<=[A-Za-z_][A-Za-z0-9_.-]*/ contained

" Variables created by @let use paired dollars; $slide_number is the one
" built-in, intentionally single-ended variable exposed by the renderer.
syntax match rayslidesVariable /\$[A-Za-z_][A-Za-z0-9_]*\$/ contained
syntax match rayslidesVariable /\$slide_number\>/ contained

" Literal classes. Colors are #RRGGBBAA, matching parseColorLiteral exactly.
" The number boundary excludes identifiers and filenames without relying on
" expensive backtracking across a line.
syntax match rayslidesNumber /\%([=[:space:](]\)\@<=[-+]\=\%([0-9]\+\%\(\.[0-9]*\)\=\|\.[0-9]\+\)\%([eE][-+]\=[0-9]\+\)\=\ze\%($\|[[:space:])]\)/ contained
syntax match rayslidesDimension /\<[0-9]\+x[0-9]\+\>/ contained
syntax match rayslidesColor /#[0-9A-Fa-f]\{8}/ contained
syntax match rayslidesBoolean /\%(\<\%(visible\|locked\)=\)\@<=\%(true\|false\)\>/ contained
syntax match rayslidesBoolean /\%(\<open=\)\@<=\%(true\|false\|yes\|no\|0\|1\)\>/ contained
syntax match rayslidesBoolean /\%(\<\%(autoplay\|loop\|muted\)=\)\@<=\%(true\|false\|yes\|no\|0\|1\)\>/ contained
syntax match rayslidesBoolean /\<\%(autoplay\|loop\|muted\)\>\ze\%($\|\s\)/ contained

" Closed parser vocabularies are highlighted only in the positions where
" they are meaningful, avoiding false positives in IDs and prose.
syntax match rayslidesEnum /\%(@anim(\)\@<=\%(none\|appear\|fade\|slide-left\|slide-right\|slide-up\|slide-down\)\ze)/ contained
syntax match rayslidesEnum /\%(@state(\)\@<=morph\ze)/ contained
syntax match rayslidesEnum /\%(\<\%(anim\|effect\|transition\)=\)\@<=\%(none\|appear\|fade\|slide-left\|slide-right\|slide-up\|slide-down\)\>/ contained
syntax match rayslidesEnum /\%(^@anim\s\+\)\@<=\%(none\|appear\|fade\|slide-left\|slide-right\|slide-up\|slide-down\)\>/ contained
syntax match rayslidesEnum /\%(\<by=\)\@<=\%(item\|line\|bullet\)\>/ contained
syntax match rayslidesEnum /\%(\<ease=\)\@<=\%(linear\|smooth\|spring\)\>/ contained
syntax match rayslidesEnum /\%(^@transition_ease=\)\@<=\%(linear\|smooth\|spring\)\>/ contained
syntax match rayslidesEnum /\%(\<align=\)\@<=\%(left\|center\|right\)\>/ contained
syntax match rayslidesEnum /\%(\<valign=\)\@<=\%(top\|middle\|bottom\)\>/ contained
syntax match rayslidesEnum /\%(\<direction=\)\@<=\%(up\|down\)\>/ contained
syntax match rayslidesEnum /\%(\<arrow=\)\@<=\%(none\|start\|end\|both\)\>/ contained
syntax match rayslidesEnum /\%(\<\%(bg\|shadow\)=\)\@<=none\>/ contained
syntax match rayslidesEnum /\%(\<fit=\)\@<=\%(stretch\|contain\|cover\|fit\|fill\)\>/ contained
syntax match rayslidesEnum /\%(\<cam_format=\)\@<=\%(auto\|mjpeg\|yuyv422\|nv12\|h264\)\>/ contained
syntax match rayslidesEnum /\%(\<delay=\)\@<=click\>/ contained
syntax match rayslidesEnum /\%(^@crowd\s\+\)\@<=\%(join\|poll\)\>/ contained

" File and font values are whitespace-delimited in item directives. Global
" font values may occupy the rest of the line. Quotation marks have no
" escaping semantics in the parser and are therefore not presented as a way
" to put spaces into a path.
syntax match rayslidesString /\%(\<\%(img\|vid\|cam\|poster_image\|bullet_symbol\)=\)\@<=\S\+/ contained contains=rayslidesVariable
syntax match rayslidesString /\%(^@\%(font\|font_bold\|font_italic\|font_bold_italic\|font_extra\|bullet_symbol\)=\)\@<=.\+$/ contained contains=rayslidesVariable
syntax match rayslidesString /\%(^@let\s\+[A-Za-z_][A-Za-z0-9_-]*\s*=\)\@<=.\+$/ contained contains=@rayslidesInline,rayslidesVariable,rayslidesColor,rayslidesNumber,rayslidesBoolean
syntax match rayslidesTextValue /\%(\<text=\)\@<=.\+$/ contained contains=@rayslidesInline,rayslidesVariable,@Spell

" Rayslides' intentionally small Markdown-like inline language. These are
" line-local because the renderer parses one source line at a time.
syntax region rayslidesBold matchgroup=rayslidesMarkup start=/\*\*/ end=/\*\*/ oneline contained contains=rayslidesItalic,rayslidesUnderline,rayslidesExtraFont,rayslidesInlineColor,rayslidesVariable,@Spell
syntax region rayslidesItalic matchgroup=rayslidesMarkup start=/_/ end=/_/ oneline contained contains=rayslidesBold,rayslidesUnderline,rayslidesExtraFont,rayslidesInlineColor,rayslidesVariable,@Spell
syntax region rayslidesUnderline matchgroup=rayslidesMarkup start=/\~\~/ end=/\~\~/ oneline contained contains=rayslidesBold,rayslidesItalic,rayslidesExtraFont,rayslidesInlineColor,rayslidesVariable,@Spell
syntax region rayslidesExtraFont matchgroup=rayslidesMarkup start=/!/ end=/!/ oneline contained contains=rayslidesBold,rayslidesItalic,rayslidesUnderline,rayslidesInlineColor,rayslidesVariable
syntax region rayslidesExtraFont matchgroup=rayslidesMarkup start=/`/ end=/`/ oneline contained contains=rayslidesBold,rayslidesItalic,rayslidesUnderline,rayslidesInlineColor,rayslidesVariable
syntax region rayslidesInlineColor matchgroup=rayslidesColor start=/<#[0-9A-Fa-f]\{8}>/ end=/<\/>/ oneline contained contains=rayslidesBold,rayslidesItalic,rayslidesUnderline,rayslidesExtraFont,rayslidesVariable,@Spell

syntax cluster rayslidesInline contains=rayslidesBold,rayslidesItalic,rayslidesUnderline,rayslidesExtraFont,rayslidesInlineColor,rayslidesVariable

" Speaker notes are literal private prose. An exact, unindented @endnotes
" closes the block; directive-looking lines and leading hashes inside it must
" not be interpreted as source syntax.
syntax region rayslidesNotes matchgroup=rayslidesDirective start=/^@notes\>/ end=/^@endnotes\s*$/ keepend contains=rayslidesTodo,@Spell

highlight default link rayslidesTodo Todo
highlight default link rayslidesComment Comment
highlight default link rayslidesBullet Special
highlight default link rayslidesBlankLine Special
highlight default link rayslidesUnknownDirective Error
highlight default link rayslidesUnknownAttribute Error
highlight default link rayslidesDirective Keyword
highlight default link rayslidesAttribute Type
highlight default link rayslidesOperator Operator
highlight default link rayslidesDelimiter Delimiter
highlight default link rayslidesDefinition Identifier
highlight default link rayslidesReference Identifier
highlight default link rayslidesVariable Identifier
highlight default link rayslidesNumber Number
highlight default link rayslidesDimension Number
highlight default link rayslidesColor Constant
highlight default link rayslidesBoolean Boolean
highlight default link rayslidesEnum Constant
highlight default link rayslidesString String
highlight default link rayslidesTextValue String
highlight default link rayslidesMarkup Special
highlight default link rayslidesBold Statement
highlight default link rayslidesItalic PreProc
highlight default link rayslidesUnderline Underlined
highlight default link rayslidesExtraFont Special
highlight default link rayslidesInlineColor String
highlight default link rayslidesNotes Comment

let b:current_syntax = 'rayslides'
