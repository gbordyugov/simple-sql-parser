
The parser uses a separate lexer for two reasons:

1. sql syntax is very awkward to parse, the separate lexer makes it
easier to handle this in most places (in some places it makes it
harder or impossible, the fix is to switch to something better than
parsec)

2. using a separate lexer gives a huge speed boost because it reduces
backtracking. (We could get this by making the parsing code a lot more
complex also.)

= Lexing and dialects

The main dialect differences:

symbols follow different rules in different dialects

e.g. postgresql has a flexible extensible-ready syntax for operators
which are parsed here as symbols

sql server using [] for quoting identifiers, and so they don't parse
as symbols here (in other dialects including ansi, these are used for
array operations)

quoting of identifiers is different in different dialects

there are various other identifier differences:
ansi has :host_param
there are variants on these like in @sql_server adn in #oracle

string quoting follows different rules in different dialects,
e.g. postgresql has $$ quoting

todo: public documentation on dialect definition - and dialect flags



> -- | This is the module contains a Lexer for SQL.
> {-# LANGUAGE TupleSections #-}
> module Language.SQL.SimpleSQL.Lex
>     (Token(..)
>     ,lexSQL
>     ,prettyToken
>     ,prettyTokens
>     ,ParseError(..)
>     ,Dialect(..)
>     ,tokensWillPrintAndLex
>     ,tokenListWillPrintAndLex
>     ) where

> import Language.SQL.SimpleSQL.Dialect

> import Text.Parsec (option,string,manyTill,anyChar
>                    ,try,string,many1,oneOf,digit,(<|>),choice,char,eof
>                    ,many,runParser,lookAhead,satisfy
>                    ,setPosition,getPosition
>                    ,setSourceColumn,setSourceLine
>                    ,sourceName, setSourceName
>                    ,sourceLine, sourceColumn
>                    ,notFollowedBy)
> import Language.SQL.SimpleSQL.Combinators
> import Language.SQL.SimpleSQL.Errors
> import Control.Applicative hiding ((<|>), many)
> import Data.Char
> import Control.Monad
> import Prelude hiding (takeWhile)
> import Text.Parsec.String (Parser)
> import Data.Maybe


> -- | Represents a lexed token
> data Token
>     -- | A symbol (in ansi dialect) is one of the following
>     --
>     -- * multi char symbols <> <= >= != ||
>     -- * single char symbols: * + -  < >  ^ / %  ~ & | ? ( ) [ ] , ; ( )
>     --
>     = Symbol String
>
>     -- | This is an identifier or keyword. The first field is
>     -- the quotes used, or nothing if no quotes were used. The quotes
>     -- can be " or u& or something dialect specific like []
>     | Identifier (Maybe (String,String)) String
>
>     -- | This is a host param symbol, e.g. :param
>     | HostParam String
>
>     -- | This is a prefixed variable symbol, such as @var or #var (not used in ansi dialect)
>     | PrefixedVariable Char String
>
>     -- | This is a positional arg identifier e.g. $1
>     | PositionalArg Int
>
>     -- | This is a string literal. The first two fields are the --
>     -- start and end quotes, which are usually both ', but can be
>     -- the character set (one of nNbBxX, or u&, U&), or a dialect
>     -- specific string quoting (such as $$ in postgres)
>     | SqlString String String String
>
>     -- | A number literal (integral or otherwise), stored in original format
>     -- unchanged
>     | SqlNumber String
>
>     -- | Whitespace, one or more of space, tab or newline.
>     | Whitespace String
>
>     -- | A commented line using --, contains every character starting with the
>     -- \'--\' and including the terminating newline character if there is one
>     -- - this will be missing if the last line in the source is a line comment
>     -- with no trailing newline
>     | LineComment String
>
>     -- | A block comment, \/* stuff *\/, includes the comment delimiters
>     | BlockComment String
>
>       deriving (Eq,Show)



> -- | Pretty printing, if you lex a bunch of tokens, then pretty
> -- print them, should should get back exactly the same string
> prettyToken :: Dialect -> Token -> String
> prettyToken _ (Symbol s) = s
> prettyToken _ (Identifier Nothing t) = t
> prettyToken _ (Identifier (Just (q1,q2)) t) = q1 ++ t ++ q2
> prettyToken _ (HostParam p) = ':':p
> prettyToken _ (PrefixedVariable c p) = c:p
> prettyToken _ (PositionalArg p) = '$':show p
> prettyToken _ (SqlString s e t) = s ++ t ++ e
> prettyToken _ (SqlNumber r) = r
> prettyToken _ (Whitespace t) = t
> prettyToken _ (LineComment l) = l
> prettyToken _ (BlockComment c) = c

> prettyTokens :: Dialect -> [Token] -> String
> prettyTokens d ts = concat $ map (prettyToken d) ts

TODO: try to make all parsers applicative only

> -- | Lex some SQL to a list of tokens.
> lexSQL :: Dialect
>                   -- ^ dialect of SQL to use
>                -> FilePath
>                   -- ^ filename to use in error messages
>                -> Maybe (Int,Int)
>                   -- ^ line number and column number of the first character
>                   -- in the source to use in error messages
>                -> String
>                   -- ^ the SQL source to lex
>                -> Either ParseError [((String,Int,Int),Token)]
> lexSQL dialect fn' p src =
>     let (l',c') = fromMaybe (1,1) p
>     in either (Left . convParseError src) Right
>        $ runParser (setPos (fn',l',c') *> many (sqlToken dialect) <* eof) () fn' src
>   where
>     setPos (fn,l,c) = do
>         fmap (flip setSourceName fn
>                . flip setSourceLine l
>                . flip setSourceColumn c) getPosition
>           >>= setPosition

> -- | parser for a sql token
> sqlToken :: Dialect -> Parser ((String,Int,Int),Token)
> sqlToken d = do
>     p' <- getPosition
>     let p = (sourceName p',sourceLine p', sourceColumn p')

The order of parsers is important: strings and quoted identifiers can
start out looking like normal identifiers, so we try to parse these
first and use a little bit of try. Line and block comments start like
symbols, so we try these before symbol. Numbers can start with a . so
this is also tried before symbol (a .1 will be parsed as a number, but
. otherwise will be parsed as a symbol).

>     (p,) <$> choice [sqlString d
>                     ,identifier d
>                     ,hostParam d
>                     ,lineComment d
>                     ,blockComment d
>                     ,sqlNumber d
>                     ,positionalArg d
>                     ,dontParseEndBlockComment d
>                     ,prefixedVariable d
>                     ,symbol d
>                     ,sqlWhitespace d]

Parses identifiers:

simple_identifier_23
u&"unicode quoted identifier"
"quoted identifier"
"quoted identifier "" with double quote char"
`mysql quoted identifier`

> identifier :: Dialect -> Parser Token
> identifier d =
>     choice
>     [Identifier (Just ("\"","\"")) <$> qiden
>      -- try is used here to avoid a conflict with identifiers
>      -- and quoted strings which also start with a 'u'
>     ,Identifier (Just ("u&\"","\"")) <$> (try (string "u&") *> qiden)
>     ,Identifier (Just ("U&\"","\"")) <$> (try (string "U&") *> qiden)
>     ,Identifier Nothing <$> identifierString
>      -- todo: dialect protection
>     ,Identifier (Just ("`","`")) <$> mySqlQIden
>     ]
>   where
>     qiden = char '"' *> qidenSuffix ""
>     qidenSuffix t = do
>         s <- takeTill (=='"')
>         void $ char '"'
>         -- deal with "" as literal double quote character
>         choice [do
>                 void $ char '"'
>                 qidenSuffix $ concat [t,s,"\"\""]
>                ,return $ concat [t,s]]
>     -- mysql can quote identifiers with `
>     mySqlQIden = do
>         guard (diSyntaxFlavour d == MySQL)
>         char '`' *> takeWhile1 (/='`') <* char '`'

This parses a valid identifier without quotes.

> identifierString :: Parser String
> identifierString =
>     startsWith (\c -> c == '_' || isAlpha c)
>                (\c -> c == '_' || isAlphaNum c)


Parse a SQL string. Examples:

'basic string'
'string with '' a quote'
n'international text'
b'binary string'
x'hexidecimal string'


> sqlString :: Dialect -> Parser Token
> sqlString d = dollarString <|> csString <|> normalString
>   where
>     dollarString = do
>         guard $ diSyntaxFlavour d == Postgres
>         -- use try because of ambiguity with symbols and with
>         -- positional arg
>         s <- choice
>              [do
>               i <- try (char '$' *> identifierString <* char '$')
>               return $ "$" ++ i ++ "$"
>              ,try (string "$$")
>              ]
>         str <- manyTill anyChar (try $ string s)
>         return $ SqlString s s str
>     normalString = SqlString "'" "'" <$> (char '\'' *> normalStringSuffix False "")
>     normalStringSuffix allowBackslash t = do
>         s <- takeTill $ if allowBackslash
>                         then (`elem` "'\\")
>                         else (== '\'')
>         -- deal with '' or \' as literal quote character
>         choice [do
>                 ctu <- choice ["''" <$ try (string "''")
>                               ,"\\'" <$ string "\\'"
>                               ,"\\" <$ char '\\']
>                 normalStringSuffix allowBackslash $ concat [t,s,ctu]
>                ,concat [t,s] <$ char '\'']
>     -- try is used to to avoid conflicts with
>     -- identifiers which can start with n,b,x,u
>     -- once we read the quote type and the starting '
>     -- then we commit to a string
>     -- it's possible that this will reject some valid syntax
>     -- but only pathalogical stuff, and I think the improved
>     -- error messages and user predictability make it a good
>     -- pragmatic choice
>     csString
>       | diSyntaxFlavour d == Postgres =
>         choice [SqlString <$> try (string "e'" <|> string "E'")
>                           <*> return "'" <*> normalStringSuffix True ""
>                ,csString']
>       | otherwise = csString'
>     csString' = SqlString
>                 <$> try cs
>                 <*> return "'"
>                 <*> normalStringSuffix False ""
>     csPrefixes = "nNbBxX"
>     cs = choice $ (map (\x -> string ([x] ++ "'")) csPrefixes)
>                   ++ [string "u&'"
>                      ,string "U&'"]

> hostParam :: Dialect -> Parser Token

use try for postgres because we also support : and :: as symbols
There might be a problem with parsing e.g. a[1:b]

> hostParam d | diSyntaxFlavour d == Postgres =
>     HostParam <$> try (char ':' *> identifierString)

> hostParam _ = HostParam <$> (char ':' *> identifierString)

> prefixedVariable :: Dialect -> Parser Token
> prefixedVariable  d | diSyntaxFlavour d == SQLServer =
>     PrefixedVariable <$> char '@' <*> identifierString
> prefixedVariable  d | diSyntaxFlavour d == Oracle =
>     PrefixedVariable <$> char '#' <*> identifierString
> prefixedVariable _ = guard False *> fail "unpossible"

> positionalArg :: Dialect -> Parser Token
> positionalArg d | diSyntaxFlavour d == Postgres =
>   -- use try to avoid ambiguities with other syntax which starts with dollar
>   PositionalArg <$> try (char '$' *> (read <$> many1 digit))
> positionalArg _ = guard False *> fail "unpossible"


digits
digits.[digits][e[+-]digits]
[digits].digits[e[+-]digits]
digitse[+-]digits

where digits is one or more decimal digits (0 through 9). At least one
digit must be before or after the decimal point, if one is used. At
least one digit must follow the exponent marker (e), if one is
present. There cannot be any spaces or other characters embedded in
the constant. Note that any leading plus or minus sign is not actually
considered part of the constant; it is an operator applied to the
constant.

> sqlNumber :: Dialect -> Parser Token
> sqlNumber _ =
>     SqlNumber <$> completeNumber
>     -- this is for definitely avoiding possibly ambiguous source
>     <* notFollowedBy (oneOf "eE.")
>   where
>     completeNumber =
>       (int <??> (pp dot <??.> pp int)
>       -- try is used in case we read a dot
>       -- and it isn't part of a number
>       -- if there are any following digits, then we commit
>       -- to it being a number and not something else
>       <|> try ((++) <$> dot <*> int))
>       <??> pp expon

>     int = many1 digit
>     dot = string "."
>     expon = (:) <$> oneOf "eE" <*> sInt
>     sInt = (++) <$> option "" (string "+" <|> string "-") <*> int
>     pp = (<$$> (++))


A symbol is one of the two character symbols, or one of the single
character symbols in the two lists below.

> symbol :: Dialect -> Parser Token
> symbol d | diSyntaxFlavour d == Postgres =
>     Symbol <$> choice (otherSymbol ++ [singlePlusMinus,opMoreChars])

rules

An operator name is a sequence of up to NAMEDATALEN-1 (63 by default) characters from the following list:

+ - * / < > = ~ ! @ # % ^ & | ` ?

There are a few restrictions on operator names, however:
-- and /* cannot appear anywhere in an operator name, since they will be taken as the start of a comment.

A multiple-character operator name cannot end in + or -, unless the name also contains at least one of these characters:

~ ! @ # % ^ & | ` ?

>  where
>    -- other symbols are all the tokens which parse as symbols in
>    -- this lexer which aren't considered operators in postgresql
>    -- a single ? is parsed as a operator here instead of an other
>    -- symbol because this is the least complex way to do it
>    otherSymbol = many1 (char '.') :
>                  (map (try . string) ["::", ":="]
>                   ++ map (string . (:[])) "[],;():")

exception char is one of:
~ ! @ # % ^ & | ` ?
which allows the last character of a multi character symbol to be + or
-

>    allOpSymbols = "+-*/<>=~!@#%^&|`?"
>    -- these are the symbols when if part of a multi character
>    -- operator permit the operator to end with a + or - symbol
>    exceptionOpSymbols = "~!@#%^&|`?"

>    -- special case for parsing a single + or - symbol
>    singlePlusMinus = try $ do
>      c <- oneOf "+-"
>      notFollowedBy $ oneOf allOpSymbols
>      return [c]

>    -- this is used when we are parsing a potentially multi symbol
>    -- operator and we have alread seen one of the 'exception chars'
>    -- and so we can end with a + or -
>    moreOpCharsException = do
>        c <- oneOf (filter (`notElem` "-/*") allOpSymbols)
>             -- make sure we don't parse a comment starting token
>             -- as part of an operator
>             <|> try (char '/' <* notFollowedBy (char '*'))
>             <|> try (char '-' <* notFollowedBy (char '-'))
>             -- and make sure we don't parse a block comment end
>             -- as part of another symbol
>             <|> try (char '*' <* notFollowedBy (char '/'))
>        (c:) <$> option [] moreOpCharsException

>    opMoreChars = choice
>        [-- parse an exception char, now we can finish with a + -
>         (:)
>         <$> oneOf exceptionOpSymbols
>         <*> option [] moreOpCharsException
>        ,(:)
>         <$> (-- parse +, make sure it isn't the last symbol
>              try (char '+' <* lookAhead (oneOf allOpSymbols))
>              <|> -- parse -, make sure it isn't the last symbol
>                  -- or the start of a -- comment
>              try (char '-'
>                   <* notFollowedBy (char '-')
>                   <* lookAhead (oneOf allOpSymbols))
>              <|> -- parse / check it isn't the start of a /* comment
>              try (char '/' <* notFollowedBy (char '*'))
>              <|> -- make sure we don't parse */ as part of a symbol
>              try (char '*' <* notFollowedBy (char '/'))
>              <|> -- any other ansi operator symbol
>              oneOf "<>=")
>         <*> option [] opMoreChars
>        ]

> symbol d | diSyntaxFlavour d == SQLServer =
>    Symbol <$> choice (otherSymbol ++ regularOp)
>  where
>    otherSymbol = many1 (char '.') :
>                  map (string . (:[])) ",;():?"

try is used because most of the first characters of the two character
symbols can also be part of a single character symbol

>    regularOp = map (try . string) [">=","<=","!=","<>"]
>                ++ map (string . (:[])) "+-^*/%~&<>="
>                ++ [char '|' *>
>                    choice ["||" <$ char '|' <* notFollowedBy (char '|')
>                           ,return "|"]]

> symbol _ =
>    Symbol <$> choice (otherSymbol ++ regularOp)
>  where
>    otherSymbol = many1 (char '.') :
>                  map (string . (:[])) "[],;():?"

try is used because most of the first characters of the two character
symbols can also be part of a single character symbol

>    regularOp = map (try . string) [">=","<=","!=","<>"]
>                ++ map (string . (:[])) "+-^*/%~&<>=[]"
>                ++ [char '|' *>
>                    choice ["||" <$ char '|' <* notFollowedBy (char '|')
>                           ,return "|"]]



> sqlWhitespace :: Dialect -> Parser Token
> sqlWhitespace _ = Whitespace <$> many1 (satisfy isSpace)

> lineComment :: Dialect -> Parser Token
> lineComment _ =
>     (\s -> LineComment $ concat ["--",s]) <$>
>     -- try is used here in case we see a - symbol
>     -- once we read two -- then we commit to the comment token
>     (try (string "--") *> (
>         -- todo: there must be a better way to do this
>      conc <$> manyTill anyChar (lookAhead lineCommentEnd) <*> lineCommentEnd))
>   where
>     conc a Nothing = a
>     conc a (Just b) = a ++ b
>     lineCommentEnd =
>         Just "\n" <$ char '\n'
>         <|> Nothing <$ eof

Try is used in the block comment for the two symbol bits because we
want to backtrack if we read the first symbol but the second symbol
isn't there.

> blockComment :: Dialect -> Parser Token
> blockComment _ =
>     (\s -> BlockComment $ concat ["/*",s]) <$>
>     (try (string "/*") *> commentSuffix 0)
>   where
>     commentSuffix :: Int -> Parser String
>     commentSuffix n = do
>       -- read until a possible end comment or nested comment
>       x <- takeWhile (\e -> e /= '/' && e /= '*')
>       choice [-- close comment: if the nesting is 0, done
>               -- otherwise recurse on commentSuffix
>               try (string "*/") *> let t = concat [x,"*/"]
>                                    in if n == 0
>                                       then return t
>                                       else (\s -> concat [t,s]) <$> commentSuffix (n - 1)
>               -- nested comment, recurse
>              ,try (string "/*") *> ((\s -> concat [x,"/*",s]) <$> commentSuffix (n + 1))
>               -- not an end comment or nested comment, continue
>              ,(\c s -> x ++ [c] ++ s) <$> anyChar <*> commentSuffix n]


This is to improve user experience: provide an error if we see */
outside a comment. This could potentially break postgres ops with */
in (which is a stupid thing to do). In other cases, the user should
write * / instead (I can't think of any cases when this would be valid
syntax though).

> dontParseEndBlockComment :: Dialect -> Parser Token
> dontParseEndBlockComment _ =
>     -- don't use try, then it should commit to the error
>     try (string "*/") *> fail "comment end without comment start"


Some helper combinators

> startsWith :: (Char -> Bool) -> (Char -> Bool) -> Parser String
> startsWith p ps = do
>   c <- satisfy p
>   choice [(:) c <$> (takeWhile1 ps)
>          ,return [c]]

> takeWhile1 :: (Char -> Bool) -> Parser String
> takeWhile1 p = many1 (satisfy p)

> takeWhile :: (Char -> Bool) -> Parser String
> takeWhile p = many (satisfy p)

> takeTill :: (Char -> Bool) -> Parser String
> takeTill p = manyTill anyChar (peekSatisfy p)

> peekSatisfy :: (Char -> Bool) -> Parser ()
> peekSatisfy p = void $ lookAhead (satisfy p)

This utility function will accurately report if the two tokens are
pretty printed, if they should lex back to the same two tokens. This
function is used in testing (and can be used in other places), and
must not be implemented by actually trying to print and then lex
(because then we would have the risk of thinking two tokens cannot be
together when there is bug in the lexer and it should be possible to
put them together.

question: maybe pretty printing the tokens separately and then
analysing the concrete syntax without concatting the two printed
tokens together is a better way of doing this?

maybe do some quick checking to make sure this function only gives
true negatives: check pairs which return false actually fail to lex or
give different symbols in return

a good sanity test for this function is to change it to always return
true, then check that the automated tests return the same number of
successes.

> tokenListWillPrintAndLex :: Dialect -> [Token] -> Bool
> tokenListWillPrintAndLex _ [] = True
> tokenListWillPrintAndLex _ [_] = True
> tokenListWillPrintAndLex d (a:b:xs) =
>     tokensWillPrintAndLex d a b && tokenListWillPrintAndLex d (b:xs)

> tokensWillPrintAndLex :: Dialect -> Token -> Token -> Bool

> tokensWillPrintAndLex d (Symbol ":") x =
>     case prettyToken d x of
>         -- eliminate cases:
>         -- first letter of pretty x can be start of identifier
>         -- this will look like a hostparam
>         -- first letter of x is :, this will look like ::
>         -- first letter of x is =, this will look like :=
>         (a:_) | a `elem` ":_=" || isAlpha a -> False
>         _ -> True

two symbols next to eachother will fail if the symbols can combine and
(possibly just the prefix) look like a different symbol, or if they
combine to look like comment markers

check if the end of one symbol and the start of the next can form a
comment token

> tokensWillPrintAndLex d a@(Symbol {}) b@(Symbol {})
>     | a'@(_:_) <- prettyToken d a
>     , ('-':_) <- prettyToken d b
>     , last a' == '-' = False

> tokensWillPrintAndLex (Dialect {diSyntaxFlavour = Postgres}) (Symbol a) (Symbol x) =
>     (x `elem` ["+", "-"])
>     && and (map (`notElem` a) "~!@#%^&|`?")

> tokensWillPrintAndLex _ (Symbol s1) (Symbol s2) =
>    (s1,s2) `notElem`
>    [("<",">")
>    ,("<","=")
>    ,(">","=")
>    ,("!","=")
>    ,("|","|")
>    ,("||","|")
>    ,("|","||")
>    ,("||","||")
>    ,("<",">=")
>    ,("-","-")
>    ,("/","*")
>    ,("*","/")
>    ]

two whitespaces will be combined

> tokensWillPrintAndLex _ Whitespace {} Whitespace {} = False

line comment without a newline at the end will eat the next token

> tokensWillPrintAndLex _ (LineComment s@(_:_)) _ = last s == '\n'

this should never happen, but the case satisfies the haskell compiler
and isn't exactly wrong

> tokensWillPrintAndLex _ (LineComment []) _ = False

apart from two above cases, leading and trailing whitespace will always be ok

> tokensWillPrintAndLex _ Whitespace {} _ = True
> tokensWillPrintAndLex _ _ Whitespace {} = True

a symbol ending with a '-' followed by a line comment will lex back
differently, since the --- will combine and move the comment eating
some of the symbol

> tokensWillPrintAndLex _ (Symbol s) (LineComment {}) =
>    case s of
>        (_:_) -> last s /= '-'
>        _ -> True

in other situations a trailing line comment will work

> tokensWillPrintAndLex _ _ LineComment {} = True

block comments: make sure there isn't a * symbol immediately before the comment opening

> tokensWillPrintAndLex d a BlockComment {} =
>     case prettyToken d a of
>         a'@(_:_) | last a' == '*' -> False
>         _ -> True

> tokensWillPrintAndLex _ BlockComment {} _ = True



> tokensWillPrintAndLex _ Symbol {} Identifier {} = True

> tokensWillPrintAndLex _ Symbol {} HostParam {} = True
> tokensWillPrintAndLex _ Symbol {} PositionalArg {} = True
> tokensWillPrintAndLex _ Symbol {} SqlString {} = True
> tokensWillPrintAndLex (Dialect {diSyntaxFlavour = Postgres}) Symbol {} (SqlNumber ('.':_)) = False
> tokensWillPrintAndLex _ Symbol {} SqlNumber {} = True


identifier:
  symbol ok
  identifier:
    alphas then alphas: bad
    quote then quote (with same start and end quote): bad
    quote [ ] then quote [ ]: ok? this technically works, not sure if
    it is a good ui, or requiring whitepace/comment is better. See
    what sql server does
    second is quote with prefix: makes it ok
  host param: ok, but maybe should require whitespace for ui reasons
  positional arg: ok, but maybe should require whitespace for ui reasons
  string: ok, but maybe should require whitespace for ui reasons
  number: ok, but maybe should require whitespace for ui reasons

> tokensWillPrintAndLex _ Identifier {} Symbol {} = True
> tokensWillPrintAndLex _ (Identifier Nothing _) (Identifier Nothing _) = False
> tokensWillPrintAndLex _ (Identifier Nothing _) (Identifier (Just (a,_)) _) =
>     case a of
>         (a':_) | isAlpha a' -> False
>         _ -> True
> tokensWillPrintAndLex _ (Identifier Just {} _) (Identifier Nothing _) = True
> tokensWillPrintAndLex _ (Identifier (Just(_,b)) _) (Identifier (Just(c,_)) _) =
>      not (b == c)
> tokensWillPrintAndLex _ Identifier {} HostParam {} = True
> tokensWillPrintAndLex _ Identifier {} PositionalArg {} = True
> tokensWillPrintAndLex _ (Identifier Nothing _) (SqlString a _ _) =
>     case a of
>         (a':_) | isAlpha a' -> False
>         _ -> True

> tokensWillPrintAndLex _ Identifier {} SqlString {} = True
> tokensWillPrintAndLex _ (Identifier Nothing _) (SqlNumber s) =
>     case s of
>         (s':_) -> not (isDigit s')
>         _ -> True
> tokensWillPrintAndLex _ Identifier {} SqlNumber {} = True



> tokensWillPrintAndLex _ HostParam {} Symbol {} = True
> tokensWillPrintAndLex _ HostParam {} (Identifier Nothing _) = False
> tokensWillPrintAndLex _ HostParam {} (Identifier (Just (a,_)) _) =
>     case a of
>         c:_ -> not (isAlpha c)
>         [] -> False

> tokensWillPrintAndLex _ HostParam {} HostParam {} = True
> tokensWillPrintAndLex _ HostParam {} PositionalArg {} = True
> tokensWillPrintAndLex _ HostParam {} (SqlString a _ _) =
>     case a of
>         (a':_) | isAlpha a' -> False
>         _ -> True
> tokensWillPrintAndLex _ HostParam {} (SqlNumber s) =
>     case s of
>         (s':_) -> not (isDigit s')
>         _ -> True

> tokensWillPrintAndLex d PrefixedVariable {} b =
>     case prettyToken d b of
>         (h:_) | h == '_' || isAlphaNum h -> False
>         _ -> True

> tokensWillPrintAndLex (Dialect {diSyntaxFlavour = Postgres})
>                       Symbol {} (PrefixedVariable {}) = False

> tokensWillPrintAndLex _ _ PrefixedVariable {} = True


> tokensWillPrintAndLex _ PositionalArg {} Symbol {} = True
> tokensWillPrintAndLex _ PositionalArg {} Identifier {} = True
> tokensWillPrintAndLex _ PositionalArg {} HostParam {} = True
> tokensWillPrintAndLex _ PositionalArg {} PositionalArg {} = True
> tokensWillPrintAndLex _ PositionalArg {} SqlString {} = True -- todo: think carefully about dollar quoting?
> tokensWillPrintAndLex _ PositionalArg {} (SqlNumber n) =
>     case n of
>         (n':_) -> not (isDigit n')
>         _ -> True

> tokensWillPrintAndLex _ SqlString {} Symbol {} = True
> tokensWillPrintAndLex _ SqlString {} Identifier {} = True
> tokensWillPrintAndLex _ SqlString {} HostParam {} = True
> tokensWillPrintAndLex _ SqlString {} PositionalArg {} = True

> tokensWillPrintAndLex _ (SqlString _q00 q01 _s0) (SqlString q10 _q11 _s1) =
>     not (q01 == "'" && q10 == "'")

> tokensWillPrintAndLex _ SqlString {} SqlNumber {} = True

> tokensWillPrintAndLex _ SqlNumber {} (Symbol ('.':_)) = False
> tokensWillPrintAndLex _ SqlNumber {} Symbol {} = True
> tokensWillPrintAndLex _ SqlNumber {} Identifier {} = True
> tokensWillPrintAndLex _ SqlNumber {} HostParam {} = True
> tokensWillPrintAndLex _ SqlNumber {} PositionalArg {} = True

todo: check for failures when e following number is fixed

> tokensWillPrintAndLex _ SqlNumber {} (SqlString ('e':_) _ _)  = False
> tokensWillPrintAndLex _ SqlNumber {} (SqlString ('E':_) _ _)  = False
> tokensWillPrintAndLex _ SqlNumber {} SqlString {}  = True

> tokensWillPrintAndLex _ (SqlNumber _) (SqlNumber _) = False

todo: special case lexer so a second ., and . and e are not
allowed after exponent when there is no whitespace, even if there
is an unambiguous parse

TODO:

refactor the tokenswillprintlex to be based on pretty printing the
 individual tokens

start adding negative / different parse dialect tests

lex @variable in sql server
lex [quoted identifier] in sql server
lex #variable in oracle

make a new ctor for @var, #var

add token tables and tests for oracle, sql server
review existing tables

look for refactoring opportunities, especially the token
generation tables in the tests

add odbc as a dialect flag and include {} as symbols when enabled


do some user documentation on lexing, and lexing/dialects

start thinking about a more separated design for the dialect handling