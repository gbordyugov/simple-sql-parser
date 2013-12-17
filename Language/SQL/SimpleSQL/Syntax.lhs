
> -- | The AST for SQL queries
> module Language.SQL.SimpleSQL.Syntax
>     (-- * Scalar expressions
>      ScalarExpr(..)
>     ,Name(..)
>     ,TypeName(..)
>     ,Duplicates(..)
>     ,Direction(..)
>     ,InThing(..)
>     ,SubQueryExprType(..)
>      -- * Query expressions
>     ,QueryExpr(..)
>     ,makeSelect
>     ,CombineOp(..)
>     ,Corresponding(..)
>     ,Alias(..)
>      -- ** From
>     ,TableRef(..)
>     ,JoinType(..)
>     ,JoinCondition(..)
>     ) where

> -- | Represents a scalar expression
> data ScalarExpr
>     = -- | a numeric literal optional decimal point, e+-
>       -- integral exponent, e.g
>       --
>       -- * 10
>       --
>       -- * 10.
>       --
>       -- * .1
>       --
>       -- * 10.1
>       --
>       -- * 1e5
>       --
>       -- * 12.34e-6
>       NumLit String
>       -- | string literal, currently only basic strings between
>       -- single quotes without escapes (no single quotes in strings
>       -- then)
>     | StringLit String
>       -- | text of interval literal, units of interval precision,
>       -- e.g. interval 3 days (3)
>     | IntervalLit String String (Maybe Int)
>       -- | identifier without dots
>     | Iden Name
>       -- | identifier with one dot
>     | Iden2 Name Name
>       -- | star
>     | Star
>       -- | star with qualifier, e.g t.*
>     | Star2 Name
>       -- | function application (anything that looks like c style
>       -- function application syntactically)
>     | App Name [ScalarExpr]
>       -- | aggregate application, which adds distinct or all, and
>       -- order by, to regular function application
>     | AggregateApp Name (Maybe Duplicates)
>                    [ScalarExpr]
>                    [(ScalarExpr,Direction)]
>       -- | window application, which adds over (partition by a order
>       -- by b) to regular function application. Explicit frames are
>       -- not currently supported
>     | WindowApp Name [ScalarExpr] [ScalarExpr] [(ScalarExpr,Direction)]
>       -- | Infix binary operators. This is used for symbol operators
>       -- (a + b), keyword operators (a and b) and multiple keyword
>       -- operators (a is similar to b)
>     | BinOp ScalarExpr Name ScalarExpr
>       -- | Prefix unary operators. This is used for symbol
>       -- operators, keyword operators and multiple keyword operators
>     | PrefixOp Name ScalarExpr
>       -- | Postfix unary operators. This is used for symbol
>       -- operators, keyword operators and multiple keyword operators
>     | PostfixOp Name ScalarExpr
>       -- | Used for ternary, mixfix and other non orthodox
>       -- operators, including the function looking calls which use
>       -- keywords instead of commas to separate the arguments,
>       -- e.g. substring(t from 1 to 5)
>     | SpecialOp Name [ScalarExpr]
>       -- | case expression. both flavours supported. Multiple
>       -- condition when branches not currently supported (case when
>       -- a=4,b=5 then x end)
>     | Case (Maybe ScalarExpr) -- test value
>            [(ScalarExpr,ScalarExpr)] -- when branches
>            (Maybe ScalarExpr) -- else value
>     | Parens ScalarExpr
>       -- | cast(a as typename)
>     | Cast ScalarExpr TypeName
>       -- | prefix 'typed literal', e.g. int '42'
>     | TypedLit TypeName String
>       -- | exists, all, any, some subqueries
>     | SubQueryExpr SubQueryExprType QueryExpr
>       -- | in list literal and in subquery, if the bool is false it
>       -- means not in was used ('a not in (1,2)')
>     | In Bool ScalarExpr InThing
>       deriving (Eq,Show,Read)

> -- | Represents an identifier name, which can be quoted or unquoted
> data Name = Name String
>           | QName String
>           deriving (Eq,Show,Read)

> -- | Represents a type name, used in casts.
> data TypeName = TypeName String deriving (Eq,Show,Read)


> -- | Used for 'expr in (scalar expression list)', and 'expr in
> -- (subquery)' syntax
> data InThing = InList [ScalarExpr]
>              | InQueryExpr QueryExpr
>              deriving (Eq,Show,Read)

> -- | A subquery in a scalar expression
> data SubQueryExprType
>     = -- | exists (query expr)
>       SqExists
>       -- | a scalar subquery
>     | SqSq
>       -- | all (query expr)
>     | SqAll
>       -- | some (query expr)
>     | SqSome
>       -- | any (query expr)
>     | SqAny
>       deriving (Eq,Show,Read)

> -- | Represents a query expression, which can be:
> --
> -- * a regular select;
> --
> -- * a set operator (union, except, intersect);
> --
> -- * a common table expression (with);
> --
> -- * a values expression (not yet supported);
> --
> -- * or the table syntax - 'table t', shorthand for 'select * from
> --    t' (not yet supported).
> data QueryExpr
>     = Select
>       {qeDuplicates :: Duplicates
>       ,qeSelectList :: [(Maybe Name,ScalarExpr)]
>        -- ^ the column aliases and the expressions
>       ,qeFrom :: [TableRef]
>       ,qeWhere :: Maybe ScalarExpr
>       ,qeGroupBy :: [ScalarExpr]
>       ,qeHaving :: Maybe ScalarExpr
>       ,qeOrderBy :: [(ScalarExpr,Direction)]
>       ,qeLimit :: Maybe ScalarExpr
>       ,qeOffset :: Maybe ScalarExpr
>       }
>     | CombineQueryExpr
>       {qe0 :: QueryExpr
>       ,qeCombOp :: CombineOp
>       ,qeDuplicates :: Duplicates
>       ,qeCorresponding :: Corresponding
>       ,qe1 :: QueryExpr
>       }
>     | With
>       {qeWithRecursive :: Bool
>       ,qeViews :: [(Alias,QueryExpr)]
>       ,qeQueryExpression :: QueryExpr}
>     | Values [[ScalarExpr]]

>       deriving (Eq,Show,Read)

TODO: add queryexpr parens to deal with e.g.
(select 1 union select 2) union select 3
I'm not sure if this is valid syntax or not.

> -- | represents the Distinct or All keywords, which can be used
> -- before a select list, in an aggregate/window function
> -- application, or in a query expression set operator
> data Duplicates = Distinct | All deriving (Eq,Show,Read)

> -- | The direction for a column in order by.
> data Direction = Asc | Desc deriving (Eq,Show,Read)
> -- | Query expression set operators
> data CombineOp = Union | Except | Intersect deriving (Eq,Show,Read)
> -- | Corresponding, an option for the set operators
> data Corresponding = Corresponding | Respectively deriving (Eq,Show,Read)

> -- | helper/'default' value for query exprs to make creating query
> -- expr values a little easier
> makeSelect :: QueryExpr
> makeSelect = Select {qeDuplicates = All
>                     ,qeSelectList = []
>                     ,qeFrom = []
>                     ,qeWhere = Nothing
>                     ,qeGroupBy = []
>                     ,qeHaving = Nothing
>                     ,qeOrderBy = []
>                     ,qeLimit = Nothing
>                     ,qeOffset = Nothing}

> -- | Represents a entry in the csv of tables in the from clause.
> data TableRef = -- | from t
>                 TRSimple Name
>                 -- | from a join b
>               | TRJoin TableRef JoinType TableRef (Maybe JoinCondition)
>                 -- | from (a)
>               | TRParens TableRef
>                 -- | from a as b(c,d)
>               | TRAlias TableRef Alias
>                 -- | from (query expr)
>               | TRQueryExpr QueryExpr
>                 -- | from function(args)
>               | TRFunction Name [ScalarExpr]
>                 -- | from lateral t
>               | TRLateral TableRef
>                 deriving (Eq,Show,Read)

> data Alias = Alias Name (Maybe [Name])
>              deriving (Eq,Show,Read)

TODO: add function table ref

> -- | The type of a join
> data JoinType = JInner | JLeft | JRight | JFull | JCross
>                 deriving (Eq,Show,Read)

> -- | The join condition.
> data JoinCondition = JoinOn ScalarExpr -- ^ on expr
>                    | JoinUsing [Name] -- ^ using (column list)
>                    | JoinNatural -- ^ natural join was used
>                      deriving (Eq,Show,Read)
