#' @export
#' @rdname sql_build
lazy_select_query <- function(x,
                              select = NULL,
                              where = NULL,
                              group_by = NULL,
                              having = NULL,
                              order_by = NULL,
                              limit = NULL,
                              distinct = FALSE,
                              group_vars = NULL,
                              order_vars = NULL,
                              frame = NULL,
                              select_operation = c("select", "mutate", "summarise"),
                              message_summarise = NULL) {
  check_lazy_query(x, call = call)
  stopifnot(is.null(select) || is_lazy_sql_part(select))
  stopifnot(is_lazy_sql_part(where))
  # stopifnot(is.character(group_by))
  stopifnot(is_lazy_sql_part(order_by))
  check_number_whole_inf(limit, allow_null = TRUE)
  check_bool(distinct)

  select <- select %||% syms(set_names(op_vars(x)))
  select_operation <- arg_match0(select_operation, c("select", "mutate", "summarise"))

  check_string(message_summarise, allow_null = TRUE)

  # inherit `group_vars`, `order_vars`, and `frame` from `from`
  group_vars <- group_vars %||% op_grps(x)
  order_vars <- order_vars %||% op_sort(x)
  frame <- frame %||% op_frame(x)

  if (select_operation == "mutate") {
    select <- new_lazy_select(
      select,
      group_vars = group_vars,
      order_vars = order_vars,
      frame = frame
    )
  } else {
    select <- new_lazy_select(select)
  }

  lazy_query(
    query_type = "select",
    x = x,
    select = select,
    where = where,
    group_by = group_by,
    order_by = order_by,
    distinct = distinct,
    limit = limit,
    select_operation = select_operation,
    message_summarise = message_summarise,
    group_vars = group_vars,
    order_vars = order_vars,
    frame = frame
  )
}

is_lazy_sql_part <- function(x) {
  if (is.null(x)) return(TRUE)
  if (is_quosures(x)) return(TRUE)

  if (!is.list(x)) return(FALSE)
  purrr::every(x, ~ is_quosure(.x) || is_symbol(.x) || is_call(.x))
}

new_lazy_select <- function(vars,
                            group_vars = character(),
                            order_vars = NULL,
                            frame = NULL) {
  vctrs::vec_as_names(names2(vars), repair = "check_unique")

  var_names <- names(vars)
  vars <- unname(vars)

  tibble(
    name = var_names %||% character(),
    expr = vars %||% list(),
    group_vars = rep_along(vars, list(group_vars)),
    order_vars = rep_along(vars, list(order_vars)),
    frame = rep_along(vars, list(frame))
  )
}

# projection = only select (including rename) from parent query
# identity = selects exactly the same variable as the parent query
is_lazy_select_query_simple <- function(x,
                                        ignore_group_by = FALSE,
                                        select = c("projection", "identity")) {
  select <- arg_match(select, c("projection", "identity"))
  if (!inherits(x, "lazy_select_query")) {
    return(FALSE)
  }

  if (select == "projection" && !is_projection(x$select$expr)) {
    return(FALSE)
  }

  if (select == "identity" && !is_select_identity(x$select, op_vars(x$x))) {
    return(FALSE)
  }

  if (!is_empty(x$where)) {
    return(FALSE)
  }
  if (!ignore_group_by && !is_empty(x$group_by)) {
    return(FALSE)
  }
  if (!is_empty(x$order_by)) {
    return(FALSE)
  }
  if (is_true(x$distinct)) {
    return(FALSE)
  }
  if (!is_empty(x$limit)) {
    return(FALSE)
  }

  TRUE
}

is_select_identity <- function(select, vars_prev) {
  is_identity(select$expr, select$name, vars_prev)
}


#' @export
print.lazy_select_query <- function(x, ...) {
  cat(
    "<SQL SELECT",
    if (x$distinct) " DISTINCT", ">\n",
    sep = ""
  )
  cat_line("From:")
  cat_line(indent_print(sql_build(x$x, simulate_dbi())))

  select <- purrr::set_names(x$select$expr, x$select$name)
  if (length(select))     cat("Select:   ", named_commas2(select), "\n", sep = "")
  if (length(x$where))    cat("Where:    ", named_commas2(x$where), "\n", sep = "")
  if (length(x$group_by)) cat("Group by: ", named_commas2(x$group_by), "\n", sep = "")
  if (length(x$order_by)) cat("Order by: ", named_commas2(x$order_by), "\n", sep = "")
  if (length(x$limit))    cat("Limit:    ", x$limit, "\n", sep = "")

  if (length(x$group_vars)) cat("group_vars: ", named_commas2(x$group_vars), "\n", sep = "")
  if (length(x$order_vars)) cat("order_vars: ", named_commas2(x$order_vars), "\n", sep = "")
  if (length(x$frame))    cat("frame:    ", x$frame, "\n", sep = "")
}

named_commas2 <- function(x) {
  x <- purrr::map_chr(x, as_label)
  nms <- names2(x)
  out <- ifelse(nms == "", x, paste0(nms, " = ", x))
  paste0(out, collapse = ", ")
}

#' @export
op_vars.lazy_query <- function(op) {
  op$select$name
}

#' @export
op_desc.lazy_query <- function(op) {
  "SQL"
}

#' @export
sql_build.lazy_select_query <- function(op, con, ..., use_star = TRUE) {
  if (!is.null(op$message_summarise)) {
    inform(op$message_summarise)
  }

  alias <- ident(remote_name(op$x, null_if_local = FALSE) %||% unique_subquery_name())
  from <- sql_build(op$x, con, use_star = use_star)
  select_sql_list <- get_select_sql(
    select = op$select,
    select_operation = op$select_operation,
    in_vars = op_vars(op$x),
    table_alias = alias,
    con = con,
    use_star = use_star
  )
  where_sql <- translate_sql_(op$where, con = con, context = list(clause = "WHERE"))

  select_query(
    from = from,
    select = select_sql_list$select_sql,
    where = where_sql,
    group_by = translate_sql_(op$group_by, con = con),
    having = translate_sql_(op$having, con = con, window = FALSE),
    window = select_sql_list$window_sql,
    order_by = translate_sql_(op$order_by, con = con),
    distinct = op$distinct,
    limit = op$limit,
    from_alias = alias
  )
}

get_select_sql <- function(select,
                           select_operation,
                           in_vars,
                           table_alias,
                           con,
                           use_star) {
  if (select_operation == "summarise") {
    select_expr <- set_names(select$expr, select$name)
    select_sql_list <- translate_sql_(select_expr, con, window = FALSE, context = list(clause = "SELECT"))
    select_sql <- sql_vector(select_sql_list, parens = FALSE, collapse = NULL, con = con)
    return(list(select_sql = select_sql, window_sql = character()))
  }

  if (use_star && is_select_identity(select, in_vars)) {
    out <- list(
      select_sql = sql_star(con, table_alias),
      window_sql = character()
    )
    return(out)
  }

  select <- select_use_star(select, in_vars, table_alias, con, use_star)

  # translate once just to register windows
  win_register_activate()
  # Remove known windows before building the next query
  on.exit(win_reset(), add = TRUE)
  on.exit(win_register_deactivate(), add = TRUE)
  select_sql <- translate_select_sql(con, select)
  win_register_deactivate()

  named_windows <- win_register_names()
  if (nrow(named_windows) > 0 && supports_window_clause(con)) {
    # need to translate again and use registered windows names
    select_sql <- translate_select_sql(con, select)

    # build window sql
    names_esc <- sql_escape_ident(con, named_windows$name)
    window_sql <- sql(paste0(names_esc, " AS ", named_windows$key))
  } else {
    window_sql <- character()
  }

  list(
    select_sql = select_sql,
    window_sql = window_sql
  )
}

select_use_star <- function(select, vars_prev, table_alias, con, use_star) {
  if (!use_star) {
    return(select)
  }

  first_match <- vctrs::vec_match(vars_prev[[1]], select$name)
  if (is.na(first_match)) {
    return(select)
  }

  last <- first_match + length(vars_prev) - 1
  n <- vctrs::vec_size(select)

  if (n < last) {
    return(select)
  }

  test_cols <- vctrs::vec_slice(select, seq2(first_match, last))

  if (is_select_identity(test_cols, vars_prev)) {
    idx_start <- seq2(1, first_match - 1)
    idx_end <- seq2(last + 1, n)
    vctrs::vec_rbind(
      vctrs::vec_slice(select, idx_start),
      tibble(name = "", expr = list(sql_star(con, table_alias))),
      vctrs::vec_slice(select, idx_end)
    )
  } else {
    select
  }
}

translate_select_sql <- function(con, select_df) {
  select_df <- transmute(
    select_df,
    dots = set_names(expr, name),
    vars_group = .data$group_vars,
    vars_order = .data$order_vars,
    vars_frame = .data$frame
  )

  out <- purrr::pmap(
    select_df,
    function(dots, vars_group, vars_order, vars_frame) {
      translate_sql_(
        list(dots), con,
        vars_group = translate_sql_(syms(vars_group), con),
        vars_order = translate_sql_(vars_order, con, context = list(clause = "ORDER")),
        vars_frame = vars_frame[[1]],
        context = list(clause = "SELECT")
      )
    }
  )

  sql(unlist(out))
}
