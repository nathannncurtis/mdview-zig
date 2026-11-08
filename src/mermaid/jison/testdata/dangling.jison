%lex
%%
\s+     /* skip */
"if"    return 'IF';
"then"  return 'THEN';
"else"  return 'ELSE';
"x"     return 'X';
"="     return '=';
[a-z]+  return 'ID';
<<EOF>> return 'EOF';
/lex

%start prog

%%

prog
    : stmt EOF
    ;

stmt
    : IF expr THEN stmt
    | IF expr THEN stmt ELSE stmt
    | ID '=' expr
    | a
    | b
    | stmt stmt
    ;

a
    : X
    ;

b
    : X
    ;

expr
    : ID
    | expr '=' expr
    ;
