import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dict
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/yielder
import logging
import mist.{type Connection, type ResponseData}

const create_account_page = "<html>
       <body>
         <h1>Create Account</h1>
         <form action=\"/accountCreated\" method=\"post\">
           <input type=\"text\" name=\"username\" placeholder=\"Username\" />
           <input type=\"text\" name=\"password\" placeholder=\"Password\" />
           <button type=\"submit\">Send</button>
         </form>
       </body>
     </html>"

const account_created = "<html>
       <body>
         <h1>Account Created</h1>
         <a href='/'>Login</a>
       </body>
     </html>"

const index = "<html>
       <body>
         <h1>Login</h1>
         <form action=\"/login\" method=\"post\">
           <input type=\"text\" name=\"username\" placeholder=\"Username\" />
           <input type=\"text\" name=\"password\" placeholder=\"Password\" />
           <input type='hidden' name='client_ip' id='client_ip' />
           <button type=\"submit\">Send</button>
         </form>

         
<script>
  fetch('https://api.ipify.org?format=json')
    .then(res => res.json())
    .then(data => document.getElementById('client_ip').value = data.ip)
</script>
         <a href='/createAccount'>Create Account</a>
       </body>
     </html>"

pub type State {
  State(
    internal: #(Int, Int),
    engine_actor: List(process.Subject(Message)),
    users_db: dict.Dict(String, String),
    subreddit_user_db: dict.Dict(String, List(String)),
    subreddit_comment_db: dict.Dict(
      String,
      List(#(Int, Int, String, Int, String)),
    ),
    user_karma: dict.Dict(String, Int),
    user_dm_db: dict.Dict(String, dict.Dict(String, List(#(String, Int, Int)))),
    user_login_db: dict.Dict(String, String),
  )
}

pub type Message {
  Shutdown
  SetInternal(#(Int, Int))
  RegisterAccount(String, String)
  CreateSubReddit(String)
  JoinSubReddit(String, String)
  LeaveSubReddit(String, String)
  Post(String, String, String)
  Comment(String, String, Int, String)
  UpVote(String, Int)
  DownVote(String, Int)
  EngineDm(String, String, String, Int)
  UserDm(String, String, String)
  DoSomething(process.Subject(Message))
  Login(String, String, process.Subject(Bool))
  SetUser(String, String)
  GetSubreddits(process.Subject(dict.Dict(String, List(String))))
  GetPosts(
    process.Subject(dict.Dict(String, List(#(Int, Int, String, Int, String)))),
  )
  // Push(String)
  // PopGossip(process.Subject(Result(Int, Nil)))
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Shutdown -> actor.stop()
    SetInternal(#(v1, v2)) -> {
      actor.continue(State(
        #(v1, v2),
        state.engine_actor,
        state.users_db,
        state.subreddit_user_db,
        state.subreddit_comment_db,
        state.user_karma,
        state.user_dm_db,
        state.user_login_db,
      ))
    }
    RegisterAccount(username, password) -> {
      let users_db = dict.insert(state.users_db, username, password)
      // echo username
      // echo password

      actor.continue(State(
        state.internal,
        state.engine_actor,
        users_db,
        state.subreddit_user_db,
        state.subreddit_comment_db,
        state.user_karma,
        state.user_dm_db,
        state.user_login_db,
      ))
    }
    CreateSubReddit(subreddit_name) -> {
      let subreddit_user_db =
        dict.insert(state.subreddit_user_db, subreddit_name, [])
      //TODO What if subreddit already exists?

      let result = dict.get(subreddit_user_db, subreddit_name)

      let list_check = case result {
        Ok(result) -> result
        Error(_) -> []
      }

      // echo list_check
      let is_empty = list.is_empty(list_check)

      actor.continue(State(
        state.internal,
        state.engine_actor,
        state.users_db,
        subreddit_user_db,
        state.subreddit_comment_db,
        state.user_karma,
        state.user_dm_db,
        state.user_login_db,
      ))
    }
    JoinSubReddit(subreddit_name, username) -> {
      let subreddit_db =
        add_to_list_in_dict(state.subreddit_user_db, subreddit_name, username)

      actor.continue(State(
        state.internal,
        state.engine_actor,
        state.users_db,
        subreddit_db,
        state.subreddit_comment_db,
        state.user_karma,
        state.user_dm_db,
        state.user_login_db,
      ))
    }
    LeaveSubReddit(subreddit_name, username) -> {
      let subreddit_db =
        remove_from_list_in_dict(
          state.subreddit_user_db,
          subreddit_name,
          username,
        )

      actor.continue(State(
        state.internal,
        state.engine_actor,
        state.users_db,
        subreddit_db,
        state.subreddit_comment_db,
        state.user_karma,
        state.user_dm_db,
        state.user_login_db,
      ))
    }
    Post(subreddit_name, username, comment) -> {
      let #(current_comment_id, current_dm_id) = state.internal
      let current_comment_id = current_comment_id + 1

      let subreddit_comment_db =
        add_comment(state.subreddit_comment_db, subreddit_name, #(
          0,
          current_comment_id,
          username,
          0,
          comment,
        ))

      actor.continue(State(
        #(current_comment_id, current_dm_id),
        state.engine_actor,
        state.users_db,
        state.subreddit_user_db,
        subreddit_comment_db,
        state.user_karma,
        state.user_dm_db,
        state.user_login_db,
      ))
    }
    Comment(subreddit_name, username, parent_comment_id, comment) -> {
      let #(current_comment_id, current_dm_id) = state.internal
      let current_comment_id = current_comment_id + 1
      let subreddit_comment_db =
        add_comment(state.subreddit_comment_db, subreddit_name, #(
          0,
          current_comment_id,
          username,
          parent_comment_id,
          comment,
        ))

      actor.continue(State(
        #(current_comment_id, current_dm_id),
        state.engine_actor,
        state.users_db,
        state.subreddit_user_db,
        subreddit_comment_db,
        state.user_karma,
        state.user_dm_db,
        state.user_login_db,
      ))
    }
    UpVote(subreddit_name, post_comment_id) -> {
      let result = dict.get(state.subreddit_comment_db, subreddit_name)

      let comments = case result {
        Ok(result) -> result
        Error(_) -> []
      }

      let #(
        updown,
        comment_id,
        post_username,
        post_parent_comment_id,
        comment_contents,
      ) = find_comment(comments, post_comment_id)

      // echo comment_id

      let new_comment_list = delete_comment(comments, comment_id)

      // echo new_comment_list

      let updown = updown + 1

      let new_karma = update_karma_up(state.user_karma, post_username)

      let updated_comment = #(
        updown,
        comment_id,
        post_username,
        post_parent_comment_id,
        comment_contents,
      )

      let new_comment_list = list.append(new_comment_list, [updated_comment])

      let subreddit_comment_db =
        update_comment_dict(
          state.subreddit_comment_db,
          subreddit_name,
          new_comment_list,
        )

      // echo subreddit_comment_db
      // echo new_karma

      actor.continue(State(
        state.internal,
        state.engine_actor,
        state.users_db,
        state.subreddit_user_db,
        subreddit_comment_db,
        new_karma,
        state.user_dm_db,
        state.user_login_db,
      ))
    }

    DownVote(subreddit_name, post_comment_id) -> {
      let result = dict.get(state.subreddit_comment_db, subreddit_name)

      let comments = case result {
        Ok(result) -> result
        Error(_) -> []
      }

      let #(
        updown,
        comment_id,
        post_username,
        post_parent_comment_id,
        comment_contents,
      ) = find_comment(comments, post_comment_id)

      // echo comment_id

      let new_comment_list = delete_comment(comments, comment_id)

      // echo new_comment_list

      let updown = updown - 1

      let new_karma = update_karma_down(state.user_karma, post_username)

      let updated_comment = #(
        updown,
        comment_id,
        post_username,
        post_parent_comment_id,
        comment_contents,
      )

      let new_comment_list = list.append(new_comment_list, [updated_comment])

      let subreddit_comment_db =
        update_comment_dict(
          state.subreddit_comment_db,
          subreddit_name,
          new_comment_list,
        )

      // echo subreddit_comment_db

      actor.continue(State(
        state.internal,
        state.engine_actor,
        state.users_db,
        state.subreddit_user_db,
        subreddit_comment_db,
        new_karma,
        state.user_dm_db,
        state.user_login_db,
      ))
    }
    EngineDm(from_username, to_username, content, parent_comment_id) -> {
      let #(current_comment_id, current_dm_id) = state.internal

      let current_dm_id = current_dm_id + 1

      let user_dm_db =
        add_dm(
          from_username,
          to_username,
          content,
          current_dm_id,
          parent_comment_id,
          state.user_dm_db,
        )

      let user_dm_db =
        add_dm(
          to_username,
          from_username,
          content,
          current_dm_id,
          parent_comment_id,
          user_dm_db,
        )
      // echo user_dm_db

      actor.continue(State(
        #(current_comment_id, current_dm_id),
        state.engine_actor,
        state.users_db,
        state.subreddit_user_db,
        state.subreddit_comment_db,
        state.user_karma,
        user_dm_db,
        state.user_login_db,
      ))
    }
    UserDm(from_username, to_username, content) -> {
      actor.continue(State(
        state.internal,
        state.engine_actor,
        state.users_db,
        state.subreddit_user_db,
        state.subreddit_comment_db,
        state.user_karma,
        state.user_dm_db,
        state.user_login_db,
      ))
    }
    DoSomething(client) -> {
      let rand = int.random(4)

      let random_string = random_string(10)

      case rand {
        0 -> {
          process.send(
            client,
            Post(random_string, random_string, random_string),
          )
        }
        1 -> {
          process.send(
            client,
            Comment(random_string, random_string, 1, random_string),
          )
        }
        2 -> {
          process.send(client, JoinSubReddit(random_string, random_string))
        }
        _ -> Nil
      }

      actor.continue(state)
    }
    Login(username, password, login_handle) -> {
      // echo username
      // echo password

      let check = check_user(username, password, state.users_db)
      process.send(login_handle, check)

      actor.continue(state)
    }
    SetUser(ip, username) -> {
      let user_login_db = dict.insert(state.user_login_db, ip, username)

      // echo user_login_db

      actor.continue(State(
        state.internal,
        state.engine_actor,
        state.users_db,
        state.subreddit_user_db,
        state.subreddit_comment_db,
        state.user_karma,
        state.user_dm_db,
        user_login_db,
      ))
    }
    GetSubreddits(main_handle) -> {
      process.send(main_handle, state.subreddit_user_db)

      actor.continue(state)
    }
    GetPosts(main_handle) -> {
      process.send(main_handle, state.subreddit_comment_db)
      actor.continue(state)
    }
  }
}

pub fn main() {
  let user_db = dict.new()
  let subreddit_user_db = dict.new()
  let subreddit_comment_db = dict.new()
  let user_karma_db = dict.new()
  let user_dm_db = dict.new()
  let user_login_db = dict.new()

  let assert Ok(engine_actor) =
    actor.new(State(
      #(0, 0),
      [],
      user_db,
      subreddit_user_db,
      subreddit_comment_db,
      user_karma_db,
      user_dm_db,
      user_login_db,
    ))
    |> actor.on_message(handle_message)
    |> actor.start

  let engine_handle = engine_actor.data

  process.send(engine_handle, RegisterAccount("user", "pass"))
  process.send(engine_handle, CreateSubReddit("Raves"))

  logging.configure()
  logging.set_level(logging.Debug)

  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_tree.new()))

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      logging.log(
        logging.Info,
        "Got a request from: "
          <> string.inspect(mist.get_connection_info(req.body)),
      )
      case request.path_segments(req) {
        [] ->
          response.new(200)
          |> response.prepend_header("my-value", "abc")
          |> response.prepend_header("my-value", "123")
          |> response.set_body(mist.Bytes(bytes_tree.from_string(index)))
        ["createAccount"] ->
          response.new(200)
          |> response.prepend_header("my-value", "abc")
          |> response.prepend_header("my-value", "123")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string(create_account_page)),
          )
        ["ws"] ->
          mist.websocket(
            request: req,
            on_init: fn(_conn) { #(Nil, option.None) },
            on_close: fn(_state) { io.println("goodbye!") },
            handler: handle_ws_message,
          )
        ["echo"] -> echo_body(req)
        ["chunk"] -> serve_chunk(req)
        ["file", ..rest] -> serve_file(req, rest)
        ["form"] -> handle_form(req)
        ["accountCreated"] -> create_account(req, engine_handle)
        ["subredditCreated"] -> create_subreddit(req, engine_handle)
        ["createSubreddit"] -> create_subreddit_page_query(req, engine_handle)
        ["getSubreddits"] -> get_subreddits(req, engine_handle)
        ["viewSubreddit"] -> view_subreddits(req, engine_handle)
        ["login"] -> login(req, engine_handle)

        _ -> not_found
      }
    }
    |> mist.new
    |> mist.bind("localhost")
    |> mist.with_ipv6
    |> mist.port(8000)
    |> mist.start

  process.sleep_forever()
}

pub type MyMessage {
  Broadcast(String)
}

fn handle_ws_message(state, message, conn) {
  case message {
    mist.Text("ping") -> {
      let assert Ok(_) = mist.send_text_frame(conn, "pong")
      mist.continue(state)
    }
    mist.Text(msg) -> {
      logging.log(logging.Info, "Received text frame: " <> msg)
      mist.continue(state)
    }
    mist.Binary(msg) -> {
      logging.log(
        logging.Info,
        "Received binary frame ("
          <> int.to_string(bit_array.byte_size(msg))
          <> ")",
      )
      mist.continue(state)
    }
    mist.Custom(Broadcast(text)) -> {
      let assert Ok(_) = mist.send_text_frame(conn, text)
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn echo_body(request: Request(Connection)) -> Response(ResponseData) {
  let content_type =
    request
    |> request.get_header("content-type")
    |> result.unwrap("text/plain")

  mist.read_body(request, 1024 * 1024 * 10)
  |> result.map(fn(req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(req.body)))
    |> response.set_header("content-type", content_type)
  })
  |> result.lazy_unwrap(fn() {
    response.new(400)
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  })
}

fn serve_chunk(_request: Request(Connection)) -> Response(ResponseData) {
  let iter =
    ["one", "two", "three"]
    |> yielder.from_list
    |> yielder.map(fn(data) {
      process.sleep(2000)
      data
    })
    |> yielder.map(bytes_tree.from_string)

  response.new(200)
  |> response.set_body(mist.Chunked(iter))
  |> response.set_header("content-type", "text/plain")
}

fn serve_file(
  _req: Request(Connection),
  path: List(String),
) -> Response(ResponseData) {
  let file_path = string.join(path, "/")

  // Omitting validation for brevity
  mist.send_file(file_path, offset: 0, limit: option.None)
  |> result.map(fn(file) {
    let content_type = guess_content_type(file_path)
    response.new(200)
    |> response.prepend_header("content-type", content_type)
    |> response.set_body(file)
  })
  |> result.lazy_unwrap(fn() {
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  })
}

fn handle_form(req: Request(Connection)) -> Response(ResponseData) {
  let _req = mist.read_body(req, 1024 * 1024 * 30)
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn guess_content_type(_path: String) -> String {
  "application/octet-stream"
}

fn create_account(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  let assert Ok(body) = mist.read_body(req, 10_000)

  let result = bit_array.to_string(body.body)

  let body_string = case result {
    Ok(result) -> result
    Error(_) -> "Error"
  }

  let fields = string.split(body_string, "&")
  // echo fields

  let username_field = nth_string(fields, 0)
  let username_field_split = string.split(username_field, "=")
  let username = nth_string(username_field_split, 1)

  let password_field = nth_string(fields, 1)
  let password_field_split = string.split(password_field, "=")
  let password = nth_string(password_field_split, 1)
  // echo username

  process.send(engine_handle, RegisterAccount(username, password))
  // echo body_string
  // let fields = mist.parse_form(body)

  // // Extract "message" field if it exists
  // let message =
  //   mist.form_field("message", fields)
  //   |> result.unwrap("")

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(account_created)))
}

fn login(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  let assert Ok(body) = mist.read_body(req, 10_000)

  let result = bit_array.to_string(body.body)

  let body_string = case result {
    Ok(result) -> result
    Error(_) -> "Error"
  }

  let fields = string.split(body_string, "&")
  // echo fields

  let username_field = nth_string(fields, 0)
  let username_field_split = string.split(username_field, "=")
  let username = nth_string(username_field_split, 1)

  let password_field = nth_string(fields, 1)
  let password_field_split = string.split(password_field, "=")
  let password = nth_string(password_field_split, 1)

  let ip_field = nth_string(fields, 2)
  // echo ip_field
  let ip_field_split = string.split(ip_field, "=")
  let ip = nth_string(ip_field_split, 1)

  // echo username

  let login_handle = process.new_subject()
  process.send(engine_handle, Login(username, password, login_handle))
  let result = process.receive(login_handle, 100_000)
  let check = case result {
    Ok(result) -> result
    Error(_) -> False
  }

  let successful_login = "<html>
       <body>
         <h1>Logged In!</h1>
         <a href='/createSubreddit?username=" <> username <> "'>Create Subreddit</a>
       </body>
     </html>"

  let failed_login =
    "<html>
       <body>
         <h1>Account Does Not exist</h1>
         <a href='/'>Login</a>
       </body>
     </html>"

  let login_page = case check {
    True -> successful_login
    False -> failed_login
  }

  case check {
    True -> {
      process.send(engine_handle, SetUser(ip, username))
    }
    False -> Nil
  }

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(login_page)))
}

fn create_subreddit(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  let assert Ok(body) = mist.read_body(req, 10_000)

  let result = bit_array.to_string(body.body)

  let body_string = case result {
    Ok(result) -> result
    Error(_) -> "Error"
  }

  let fields = string.split(body_string, "&")
  // echo fields

  let subreddit_name_field = nth_string(fields, 0)
  let subreddit_name_field_split = string.split(subreddit_name_field, "=")
  let subreddit_name = nth_string(subreddit_name_field_split, 1)

  // let ip_field = nth_string(fields, 1)
  // let ip_field_split = string.split(ip_field, "=")
  // let ip = nth_string(ip_field_split, 1)
  let query = case req.query {
    option.Some(q) -> q
    option.None -> ""
  }

  let query_fields = string.split(query, "=")
  let username = nth_string(query_fields, 1)
  // echo ip
  // echo subreddit_name

  let subreddit_created = "<html>
       <body>
         <h1>Subreddit Created</h1>
         <a href='/getSubreddits?username=" <> username <> "'>View Subreddits</a>
       </body>
     </html>"

  process.send(engine_handle, CreateSubReddit(subreddit_name))

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(subreddit_created)))
}

fn get_subreddits(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  // let assert Ok(body) = mist.read_body(req, 10_000)

  // let result = bit_array.to_string(body.body)
  let query = case req.query {
    option.Some(q) -> q
    option.None -> ""
  }

  let fields = string.split(query, "=")
  // echo fields
  let username = nth_string(fields, 1)

  // echo fields

  let main_handle = process.new_subject()

  process.send(engine_handle, GetSubreddits(main_handle))

  let result = process.receive(main_handle, 100_000)
  let default = dict.new()

  let subreddit_db = case result {
    Ok(result) -> result
    Error(_) -> default
  }
  let keys = dict.keys(subreddit_db)

  echo keys

  let links =
    list.map(keys, fn(name) {
      "<a href='/viewSubreddit?subreddit="
      <> name
      <> "&username="
      <> username
      <> "'>"
      <> name
      <> "</a>\n"
    })

  let all_links = string.concat(links)

  let subreddits = "<html>
       <body>
         <h1>Join Subreddit</h1>" <> all_links <> "
       </body>
     </html>"

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(subreddits)))
}

fn create_subreddit_page_query(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  let assert Ok(body) = mist.read_body(req, 10_000)

  let query = case req.query {
    option.Some(q) -> q
    option.None -> ""
  }

  // echo query

  let fields = string.split(query, "=")

  let username = nth_string(fields, 1)

  // echo fields
  // echo username

  let create_subreddit_page = "<html>
       <body>
         <h1>Create Subreddit</h1>
         <form action='subredditCreated?username=" <> username <> "' method=\"post\">
           <input type=\"text\" name=\"subredditname\" placeholder=\"Subreddit Name\" />
           <button type=\"submit\">Send</button>
         </form>
       </body>
     </html>"

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(create_subreddit_page)),
  )
}

fn view_subreddits(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  let assert Ok(body) = mist.read_body(req, 10_000)

  let query = case req.query {
    option.Some(q) -> q
    option.None -> ""
  }

  // echo query

  let fields = string.split(query, "&")

  let subreddit_name = nth_string(string.split(nth_string(fields, 0), "="), 1)
  let username = nth_string(string.split(nth_string(fields, 1), "="), 1)

  process.send(engine_handle, JoinSubReddit(subreddit_name, username))

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(index)))
}

pub fn nth_string(strings: List(String), index: Int) -> String {
  case strings {
    [] -> ""
    [first, ..rest] ->
      case index == 0 {
        True -> first
        False -> {
          nth_string(rest, index - 1)
        }
      }
  }
}

pub fn add_to_list_in_dict(
  d: dict.Dict(String, List(String)),
  key: String,
  value: String,
) -> dict.Dict(String, List(String)) {
  dict.upsert(d, key, fn(existing: option.Option(List(String))) {
    case existing {
      option.Some(current_list) -> list.append(current_list, [value])
      option.None -> [value]
    }
  })
}

pub fn add_comment(
  d: dict.Dict(String, List(#(Int, Int, String, Int, String))),
  key: String,
  value: #(Int, Int, String, Int, String),
) -> dict.Dict(String, List(#(Int, Int, String, Int, String))) {
  dict.upsert(
    d,
    key,
    fn(existing: option.Option(List(#(Int, Int, String, Int, String)))) {
      case existing {
        option.Some(current_list) -> list.append(current_list, [value])
        option.None -> [value]
      }
    },
  )
}

pub fn remove_from_list_in_dict(
  d: dict.Dict(String, List(String)),
  key: String,
  value: String,
) -> dict.Dict(String, List(String)) {
  dict.upsert(d, key, fn(existing) {
    case existing {
      // Key exists → remove the value from the list
      option.Some(xs) -> list.filter(xs, fn(x) { x != value })
      // Key does not exist → nothing, return empty list
      option.None -> []
    }
  })
}

pub fn find_comment(
  xs: List(#(Int, Int, String, Int, String)),
  b: Int,
) -> #(Int, Int, String, Int, String) {
  let matches =
    list.filter(xs, fn(tuple) {
      case tuple {
        #(i, i2, s1, i3, s3) -> i2 == b
      }
    })

  case matches {
    [] -> #(0, 0, "", 0, "")
    // default tuple if not found
    [first, ..] -> first
  }
}

pub fn delete_comment(
  xs: List(#(Int, Int, String, Int, String)),
  b: Int,
) -> List(#(Int, Int, String, Int, String)) {
  list.filter(xs, fn(tuple) {
    case tuple {
      #(i, i2, s1, i3, s3) -> i2 != b
    }
  })
}

pub fn update_comment_dict(
  d: dict.Dict(String, List(#(Int, Int, String, Int, String))),
  key: String,
  new_list: List(#(Int, Int, String, Int, String)),
) -> dict.Dict(String, List(#(Int, Int, String, Int, String))) {
  dict.insert(d, key, new_list)
}

pub fn update_karma_up(
  a: dict.Dict(String, Int),
  b: String,
) -> dict.Dict(String, Int) {
  dict.upsert(a, b, fn(existing) {
    case existing {
      option.Some(value) -> value + 1
      option.None -> 1
    }
  })
}

pub fn update_karma_down(
  a: dict.Dict(String, Int),
  b: String,
) -> dict.Dict(String, Int) {
  dict.upsert(a, b, fn(existing) {
    case existing {
      option.Some(value) -> value - 1
      option.None -> -1
    }
  })
}

pub fn add_dm(
  a: String,
  b: String,
  c: String,
  e: Int,
  f: Int,
  d: dict.Dict(String, dict.Dict(String, List(#(String, Int, Int)))),
) -> dict.Dict(String, dict.Dict(String, List(#(String, Int, Int)))) {
  dict.upsert(d, a, fn(maybe_inner) {
    // If outer dict (key a) exists, use it, else start new inner dict
    let inner = case maybe_inner {
      option.Some(existing_inner) -> existing_inner
      option.None -> dict.new()
    }

    // Update the inner dict at key b
    let updated_inner =
      dict.upsert(inner, b, fn(maybe_list) {
        case maybe_list {
          option.Some(existing_list) -> list.append(existing_list, [#(c, e, 0)])
          option.None -> [#(c, e, f)]
        }
      })

    updated_inner
  })
}

@external(erlang, "erlang", "trunc")
pub fn float_to_int(x: Float) -> Int

pub fn random_string(length: Int) -> String {
  // Generate random bytes
  let bytes = crypto.strong_random_bytes(length)

  // Encode as base16 (hex) to make it readable
  let hex = bit_array.base16_encode(bytes)

  // Truncate to desired length (since hex doubles the length)
  let output = string.slice(hex, 0, length)
  output
}

pub fn check_user(a: String, b: String, c: dict.Dict(String, String)) -> Bool {
  case dict.get(c, a) {
    Ok(value) -> value == b
    Error(_) -> False
  }
}
