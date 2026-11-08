%lex
%%
\s+                   /* skip */
[0-9]+("."[0-9]+)?\b  return 'NUM';
"+"                   return '+';
"-"                   return '-';
"*"                   return '*';
"/"                   return '/';
"^"                   return '^';
"("                   return '(';
")"                   return ')';
<<EOF>>               return 'EOF';
/lex

%left '+' '-'
%left '*' '/'
%right '^'
%left UMINUS

%start expressions

%%

expressions
    : e EOF
        { return $1; }
    ;

e
    : e '+' e
    | e '-' e
    | e '*' e
    | e '/' e
    | e '^' e
    | '-' e %prec UMINUS
    | '(' e ')'
    | NUM
    ;
