# pyyaml/lib/yaml/scanner.py

# Scanner produces tokens of the following types:
# STREAM-START
# STREAM-END
# DIRECTIVE(name, value)
# DOCUMENT-START
# DOCUMENT-END
# BLOCK-SEQUENCE-START
# BLOCK-MAPPING-START
# BLOCK-END
# FLOW-SEQUENCE-START
# FLOW-MAPPING-START
# FLOW-SEQUENCE-END
# FLOW-MAPPING-END
# BLOCK-ENTRY
# FLOW-ENTRY
# KEY
# VALUE
# ALIAS(value)
# ANCHOR(value)
# TAG(value)
# SCALAR(value, plain, style)
#
# Read comments in the Scanner code for more details.
#

package YAML::Perl::Scanner;
use strict;
use warnings;
use YAML::Perl::Processor -base;

field 'next_layer' => 'reader';

field 'reader_class', -init => '"YAML::Perl::Reader"';
field 'reader', -init => '$self->create("reader")';

use YAML::Perl::Error;
use YAML::Perl::Tokens;

package YAML::Perl::Error::Scanner;
use YAML::Perl::Error::Marked -base;

package YAML::Perl::Scanner::SimpleKey;
use YAML::Perl::Base -base;

field 'token_number';
field 'required';
field 'index';
field 'line';
field 'column';
field 'mark';

package YAML::Perl::Scanner;

field done => False;

field flow_level => 0;

field tokens => [];

sub open {
    my $self = shift;
    $self->SUPER::open(@_);
    $self->fetch_stream_start();
}

field tokens_taken => 0;

field indent => -1;

field indents => [];

field allow_simple_key => True;

field possible_simple_keys => {};

# sub scan {
#     my $self = shift;
#     my @events = ();
#     while ($self->check_token()) {
#         push @events, $self->get_token();
#         print "$events[-1]\n";
#     }
#     @events;
# }

# Public methods.

sub check_token {
    # print "+check_token\n";
    my $self = shift;
    my @choices = @_;
    while ($self->need_more_tokens()) {
        $self->fetch_more_tokens();
    }
    if (@{$self->tokens}) {
        if (not @choices) {
            return True;
        }
        for my $choice (@choices) {
            if ($self->tokens->[0]->isa($choice)) {
                return True;
            }
        }
    }
    return False;
}

sub peek_token {
    # print "+peek_token\n";
    my $self = shift;
    while ($self->need_more_tokens()) {
        $self->fetch_more_tokens();
    }
    if (@{$self->tokens}) {
        return $self->tokens->[0];
    }
    return;
}

sub get_token {
    # print "+get_token\n";
    my $self = shift;
    while ($self->need_more_tokens()) {
        $self->fetch_more_tokens();
    }
    if (@{$self->tokens}) {
        $self->tokens_taken($self->tokens_taken + 1);
        return shift @{$self->tokens};
    }
    return;
}

# Private methods.

sub need_more_tokens {
    my $self = shift;
    if ($self->done) {
        return False;
    }
    if (not @{$self->tokens}) {
        return True;
    }
    $self->stale_possible_simple_keys();
    my $next = $self->next_possible_simple_key();
    if (defined($next) and $next == $self->tokens_taken) {
        return True;
    }
    return;
}

sub fetch_more_tokens {
    my $self = shift;

    $self->scan_to_next_token();

    $self->stale_possible_simple_keys();

    $self->unwind_indent($self->reader->column);

    my $ch = $self->reader->peek();

    if ($ch eq "\0") {
        return $self->fetch_stream_end();
    }

    if ($ch eq "%" and $self->check_directive()) {
        return $self->fetch_directive();
    }

    if ($ch eq "-" and $self->check_document_start()) {
        return $self->fetch_document_start;
    }

    if ($ch eq "." and $self->check_document_end()) {
        return $self->fetch_document_end;
    }

    if ($ch eq "[") {
        return $self->fetch_flow_sequence_start();
    }

    if ($ch eq "{") {
        return $self->fetch_flow_mapping_start();
    }

    if ($ch eq "]") {
        return $self->fetch_flow_sequence_end();
    }

    if ($ch eq "}") {
        return $self->fetch_flow_mapping_end();
    }

    if ($ch eq ',') {
        return $self->fetch_flow_entry();
    }

    if ($ch eq '-' and $self->check_block_entry()) {
        return $self->fetch_block_entry();
    }

    if ($ch eq '?' and $self->check_key()) {
        return $self->fetch_key();
    }

    if ($ch eq ':' and $self->check_value()) {
        return $self->fetch_value();
    }

    if ($ch eq '*') {
        return $self->fetch_alias();
    }

    if ($ch eq '&') {
        return $self->fetch_anchor();
    }

    if ($ch eq '!') {
        return $self->fetch_tag();
    }

    if ($ch eq '|' and not $self->flow_level) {
        return $self->fetch_literal();
    }

    if ($ch eq '>' and not $self->flow_level) {
        return $self->fetch_folded();
    }

    if ($ch eq "'") {
        return $self->fetch_single();
    }

    if ($ch eq '"') {
        return $self->fetch_double();
    }

    if ($self->check_plain()) {
        return $self->fetch_plain();
    }

    throw YAML::Perl::Error::Scanner(
        "while scanning for the next token found character '$ch' that cannot start any token"
    );
}

sub next_possible_simple_key {
    my $self = shift;
    my $min_token_number = undef;
    for my $level (keys %{$self->possible_simple_keys}) {
        my $key = $self->possible_simple_keys->{$level};
        if (not defined $min_token_number or
            $key->token_number < $min_token_number
        ) {
            $min_token_number = $key->token_number;
        }
    }
    return $min_token_number;
}

sub stale_possible_simple_keys {
    my $self = shift;
    for my $level (keys %{$self->possible_simple_keys}) {
        my $key = $self->possible_simple_keys->{$level};
        if ($key->line != $self->reader->line or
            $self->reader->index - $key->index > 1024
        ) {
            if ($key->required) {
                throw YAML::Perl::Error::Scanner(
                    "while scanning a simple key ", $key->mark,
                    "could not find expected ':' ", $self->get_mark()
                );
            }
            delete $self->possible_simple_keys->{$level};
        }
    }
}

sub save_possible_simple_key {
    my $self = shift;
    my $required = (not $self->flow_level and $self->indent == $self->reader->column);
    assert($self->allow_simple_key or not $required);
    if ($self->allow_simple_key) {
        $self->remove_possible_simple_key();
        my $token_number = $self->tokens_taken + @{$self->tokens};
        my $key = YAML::Perl::Scanner::SimpleKey->new(
            token_number => $token_number,
            required => $required,
            index => $self->reader->index,
            line => $self->reader->line,
            column => $self->reader->column,
            mark => $self->reader->get_mark(),
        );
        $self->possible_simple_keys->{$self->flow_level} = $key;
    }
}

sub remove_possible_simple_key {
    my $self = shift;
    if (exists $self->possible_simple_keys->{$self->flow_level}) {
        my $key = $self->possible_simple_keys->{$self->flow_level};

        if ($key->required) {
            throw YAML::Perl::Scanner::Error->new(
                "while scanning a simple key", $key->mark,
                "could not find expected ':'", $self->get_mark()
            );
        }
        delete $self->possible_simple_keys->{$self->flow_level};
    }
}

sub unwind_indent {
    my $self = shift;
    my $column = shift;
    if ($self->flow_level) {
        return;
    }
    while ($self->indent > $column) {
        my $mark = $self->reader->get_mark();
        $self->indent(pop @{$self->indents});
        push @{$self->tokens}, YAML::Perl::Token::BlockEnd->new(
            start_mark => $mark,
            end_mark => $mark,
        );
    }
}

sub add_indent {
    my $self = shift;
    my $column = shift;
    if ($self->indent < $column) {
        push @{$self->indents}, $self->indent;
        $self->indent($column);
        return True;
    }
    return False;
}

sub fetch_stream_start {
    my $self = shift;
    my $mark = $self->reader->get_mark();
    push @{$self->tokens}, YAML::Perl::Token::StreamStart->new(
        start_mark => $mark,
        end_mark => $mark,
        encoding => $self->reader->encoding,
    );
}

sub fetch_stream_end {
    my $self = shift;
    $self->unwind_indent(-1);
    $self->allow_simple_key(False);
    $self->possible_simple_keys({});
    my $mark = $self->reader->get_mark();
    push @{$self->tokens}, YAML::Perl::Token::StreamEnd->new(
        start_mark => $mark,
        end_mark => $mark,
    );
    $self->done(True);
}

sub fetch_directive {
    my $self = shift;
    $self->unwind_indent(-1);
    $self->remove_possible_simple_key();
    $self->allow_simple_key(False);
    push @{$self->tokens}, $self->scan_directive();
}

sub fetch_document_start {
    my $self = shift;
    $self->fetch_document_indicator('YAML::Perl::Token::DocumentStart');
}

sub fetch_document_end {
    my $self = shift;
    $self->fetch_document_indicator('YAML::Perl::Token::DocumentEnd');
}

sub fetch_document_indicator {
    my $self = shift;
    my $token_class = shift;
    $self->unwind_indent(-1);
    $self->remove_possible_simple_key();
    $self->allow_simple_key(False);
    my $start_mark = $self->reader->get_mark();
    $self->reader->forward(3);
    my $end_mark = $self->reader->get_mark();
    push @{$self->tokens}, $token_class->new(
        start_mark => $start_mark,
        end_mark => $end_mark,
    );
}

sub fetch_flow_sequence_start {
    my $self = shift;
    $self->fetch_flow_collection_start('YAML::Perl::Token::FlowSequenceStart');
}

sub fetch_flow_mapping_start {
    my $self = shift;
    $self->fetch_flow_collection_start('YAML::Perl::Token::FlowMappingStart');
}

sub fetch_flow_collection_start {
    my $self = shift;
    my $token_class = shift;
    $self->save_possible_simple_key();
    $self->flow_level($self->flow_level + 1);
    $self->allow_simple_key(True);
    my $start_mark = $self->reader->get_mark();
    $self->reader->forward();
    my $end_mark = $self->reader->get_mark();
    push @{$self->tokens}, $token_class->new(
        start_mark => $start_mark,
        end_mark => $end_mark,
    );
}

sub fetch_flow_sequence_end {
    my $self = shift;
    $self->fetch_flow_collection_end('YAML::Perl::Token::FlowSequenceEnd');
}

sub fetch_flow_mapping_end {
    my $self = shift;
    $self->fetch_flow_collection_end('YAML::Perl::Token::FlowMappingEnd');
}

sub fetch_flow_collection_end {
    my $self = shift;
    my $token_class = shift;
    $self->remove_possible_simple_key();
    $self->flow_level($self->flow_level - 1);
    $self->allow_simple_key(False);
    my $start_mark = $self->reader->get_mark();
    $self->reader->forward();
    my $end_mark = $self->reader->get_mark();
    push @{$self->tokens}, $token_class->new(
        start_mark => $start_mark,
        end_mark => $end_mark,
    );
}

sub fetch_flow_entry {
    my $self = shift;
    $self->allow_simple_key(True);
    $self->remove_possible_simple_key();
    my $start_mark = $self->reader->get_mark();
    $self->reader->forward();
    my $end_mark = $self->reader->get_mark();
    push @{$self->tokens}, YAML::Perl::Token::FlowEntry->new(
        start_mark => $start_mark,
        end_mark => $end_mark,
    );
}

sub fetch_block_entry {
    my $self = shift;
    if (not $self->flow_level) {
        if (not $self->allow_simple_key) {
            throw YAML::Perl::Error::Scanner(
                undef, undef,
                "sequence entries are not allowed here", $self->get_mark()
            );
        }
        if ($self->add_indent($self->reader->column)) {
            my $mark = $self->reader->get_mark();
            push @{$self->tokens}, YAML::Perl::Token::BlockSequenceStart->new(
                start_mark => $mark,
                end_mark => $mark,
            );
        }
    }
    $self->allow_simple_key(True);
    $self->remove_possible_simple_key();
    my $start_mark = $self->reader->get_mark();
    $self->reader->forward();
    my $end_mark = $self->reader->get_mark();
    push @{$self->tokens}, YAML::Perl::Token::BlockEntry->new(
        start_mark => $start_mark,
        end_mark => $end_mark,
    );
}

sub fetch_key {
    my $self = shift;
    if (not $self->flow_level) {
        if (not $self->allow_simple_key) {
            throw YAML::Perl::Error::Scanner(
                undef, undef,
                "mapping keys are not allowed here", $self->get_mark()
            );
        }
        if ($self->add_indent($self->column)) {
            my $mark = $self->reader->get_mark();
            push @{$self->tokens}, YAML::Perl::Token::BlockMappingStart->new(
                start_mark=> $mark,
                end_mark => $mark,
            );
        }
    }
    $self->allow_simple_key(not($self->flow_level));
    $self->remove_possible_simple_key();
    my $start_mark = $self->reader->get_mark();
    $self->reader->forward();
    my $end_mark = $self->reader->get_mark();
    push @{$self->tokens}, YAML::Perl::Token::Key->new(
        start_mark => $start_mark,
        end_mark => $end_mark,
    );
}

sub fetch_value {
    my $self = shift;

    if (exists $self->possible_simple_keys->{$self->flow_level}) {
        my $key = $self->possible_simple_keys->{$self->flow_level};
        delete $self->possible_simple_keys->{$self->flow_level};
        splice @{$self->tokens},
            ($key->token_number - $self->tokens_taken), 0,
            YAML::Perl::Token::Key->new(
                start_mark => $key->mark, 
                end_mark => $key->mark,
            );
        if (not $self->flow_level) {
            if ($self->add_indent($key->column)) {
                splice @{$self->tokens},
                    ($key->token_number - $self->tokens_taken), 0,
                    YAML::Perl::Token::BlockMappingStart->new(
                        start_mark => $key->mark, 
                        end_mark => $key->mark,
                    );
            }
        }
        $self->allow_simple_key(False);
    }
    else {
        die;
    }
    my $start_mark = $self->reader->get_mark();
    $self->reader->forward();
    my $end_mark = $self->reader->get_mark();
    push @{$self->tokens},
        YAML::Perl::Token::Value->new(
            start_mark => $start_mark, 
            end_mark => $end_mark,
        );
}

sub fetch_alias {
    my $self = shift;
    die "fetch_alias";
}

sub fetch_anchor {
    my $self = shift;
    die "fetch_anchor";
}

sub fetch_tag {
    my $self = shift;
    die "fetch_tag";
}

sub fetch_literal {
    my $self = shift;
    die "fetch_literal";
}

sub fetch_folded {
    my $self = shift;
    die "fetch_folded";
}

sub fetch_block_scalar {
    my $self = shift;
    die "fetch_block_scalar";
}

sub fetch_single {
    my $self = shift;
    die "fetch_single";
}

sub fetch_double {
    my $self = shift;
    die "fetch_double";
}

sub fetch_flow_scalar {
    my $self = shift;
    die "fetch_flow_scalar";
}

sub fetch_plain {
    my $self = shift;
    $self->save_possible_simple_key();
    $self->allow_simple_key(False);
    push @{$self->tokens}, $self->scan_plain();
}

sub check_directive {
    my $self = shift;
    die "check_directive";
}

sub check_document_start {
    my $self = shift;
    if ($self->reader->column == 0) {
        if ($self->reader->prefix(3) eq '---' and
            $self->reader->peek(3) =~ /^[\0\ \t\r\n\x85\x{2028}\x{2029}]$/
        ) {
            return True;
        }
    }
    return;
}

sub check_document_end {
    my $self = shift;
    die "check_document_end";
}

sub check_block_entry {
    my $self = shift;
    return $self->reader->peek(1) =~ /^[\0\ \t\r\n\x85\x{2028}\x{2029}]$/;
}

sub check_key {
    my $self = shift;
    die "check_key";
}

sub check_value {
    my $self = shift;
    if ($self->flow_level) {
        return True;
    }
    else {
        return ($self->reader->peek(1) =~ /^[\0\ \t\r\n]$/) ? True : False;
    }
}

sub check_plain {
    my $self = shift;
    my $ch = $self->reader->peek();
    return(
        $ch !~ /^[\0\ \r\n\x85\x{2028}\x{2029}\-\?\:\,\[\]\{\}\#\&\*\!\|\>\'\"\%\@\`]$/ or
        $self->reader->peek(1) !~ /^[\0\ \t\r\n\x85\x{2028}\x{2029}]$/ and
        ($ch eq '-' or (not $self->flow_level and $ch =~ /^[\?\:]$/))
    );
}

sub scan_to_next_token {
    my $self = shift;
    if ($self->reader->index == 0 and $self->reader->peek() eq "\uFEFF") {
        $self->reader->forward();
    }
    my $found = False;
    while (not $found) {
        # print ">>>> " . $self->reader->peek() . "\n";
        $self->reader->forward()
            while $self->reader->peek() eq ' ';
        if ($self->reader->peek() eq '#') {
            while ($self->reader->peek() !~ /^[\0\r\n\x85]$/) {
                $self->reader->forward();
            }
        }
        if ($self->scan_line_break()) {
            if (not $self->flow_level) {
                $self->allow_simple_key(True);
            }
        }
        else {
            $found = True;
        }
    }
    # print "<<<<\n" ;
}

sub scan_plain {
    my $self = shift;

    my $chunks = [];
    my $start_mark = $self->reader->get_mark();
    my $end_mark = $start_mark;
    my $indent = $self->indent + 1;

    my $spaces = [];

    while (True) {
        my $length = 0;
        if ($self->reader->peek() eq '#') {
            last;
        }
        my $ch;
        while (True) {
            $ch = $self->reader->peek($length);

            if (
                ($ch =~ /^[\0\ \t\r\n]$/) or
                (
                    not $self->flow_level and $ch eq ':' and
                    $self->reader->peek($length + 1) =~ /^[\0\ \t\r\n]$/
                ) or
                ($self->flow_level and $ch =~ /^[\,\:\?\[\]\{\}]$/)
            ) {
                last;
            }
            $length++;
        }
        if ($self->flow_level and
            $ch eq ':' and
            $self->reader->peek($length + 1) !~ /^[\0\ \t\r\n\,\[\]\{\}]$/
        ) {
            $self->reader->forward($length);
            throw YAML::Perl::Error::Scanner(
                "while scanning a plain scalar", $start_mark,
                "found unexpected ':'", $self->reader->get_mark(),
                "Please check http://pyyaml.org/wiki/YAMLColonInFlowContext for details.",
            );
        }
        if ($length == 0) {
            last;
        }
        $self->allow_simple_key(False);
        push @$chunks, @$spaces;
        push @$chunks, $self->reader->prefix($length);
        $self->reader->forward($length);
        $end_mark = $self->reader->get_mark();
        $spaces = $self->scan_plain_spaces($indent, $start_mark);
        if (not @$spaces or $self->reader->peek() eq '#' or
            (not $self->flow_level and $self->reader->column < $indent)
        ) {
            last;
        }
    }
    return YAML::Perl::Token::Scalar->new(
        value => join('', @$chunks),
        plain => True,
        start_mark => $start_mark,
        end_mark => $end_mark,
    );
}

#   ... ch in u'\r\n\x85\u2028\u2029':
# XXX needs unicode linefeeds 
my $linefeed = qr/^[\r\n\x85]$/;

sub scan_plain_spaces {
    my $self = shift;
    my $indent = shift;
    my $start_mark = shift;

    my $chunks = [];
    my $length = 0;
    while ($self->reader->peek( $length ) eq ' ') {
        $length++;
    }
    my $whitespaces = $self->reader->prefix($length);
    $self->reader->forward($length);
    my $ch = $self->reader->peek();
    if ($ch =~ $linefeed) {
        my $line_break = $self->scan_line_break();
        $self->allow_simple_key(True);
        my $prefix = $self->reader->prefix(3);
        if (($prefix eq '---' or $prefix eq '...') and
            $self->reader->peek(3) =~ $linefeed
        ) {
            return;
        }
        my $breaks = [];
        while ($self->reader->peek() =~ $linefeed) {
            if ($self->reader->peek() eq ' ') {
                $self->reader->forward();
            }
            else {
                push @$breaks, $self->scan_line_break();
                my $prefix = $self->reader->prefix(3);
                if (($prefix eq '---' or $prefix eq '...') and
                    $self->reader->peek(3) =~ $linefeed
                ) {
                    return;
                }
            }
        }
        if ($line_break ne "\n") {
            push @$chunks, $line_break;
        }
        elsif (not @$breaks) {
            push @$chunks, ' ';
        }
        push @$chunks, @$breaks;
    }
    elsif ($whitespaces) {
        push @$chunks, $whitespaces;
    }
    return $chunks; 
}

sub scan_line_break {
    my $self = shift;
    my $ch = $self->reader->peek();
    if ($ch =~ /[\r\n]/) {
        if ($self->reader->prefix(2) eq "\r\n") {
            $self->reader->forward(2);
        }
        else {
            $self->reader->forward(1);
        }
        return "\n"
    }
    return '';
}

1;
