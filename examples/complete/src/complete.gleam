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

const upvote_page = "<html>
       <body>
         <h1>Upvoted Comment</h1>
       </body>
     </html>"

const downvote_page = "<html>
       <body>
         <h1>Downvoted Comment</h1>
       </body>
     </html>"

const view_script = "<script>

const elements = document.getElementsByTagName('a');

  function renderCommentTree() {
  // ✅ Grab both username and subreddit from the <p id='username'> element
  const usernameEl = document.getElementById('username');
  const currentUser = usernameEl ? usernameEl.getAttribute('username') : 'Anonymous';
  const subreddit = usernameEl ? usernameEl.getAttribute('subreddit') : 'General';

  const originalElements = Array.from(document.getElementsByTagName('a'));
  // don't return early — we always want the Make Post form to exist

  const nodes = originalElements.map(el => ({
    id: el.getAttribute('id'),
    parent_id: el.getAttribute('parent_id'),
    username: el.getAttribute('username'),
    updown: parseInt(el.getAttribute('updown') || '0', 10),
    subreddit: subreddit,
    text: el.textContent.trim(),
    children: []
  }));

  const title = document.createElement('h1');
  title.textContent = subreddit;
  title.style.fontFamily = 'Arial, sans-serif';
  title.style.color = '#222';

  const postIframe = document.createElement('iframe');
  postIframe.name = 'iframe_makePost';
  postIframe.style.display = 'none';

  const makePostForm = document.createElement('form');
  makePostForm.method = 'POST';
  makePostForm.action = '/makePost';
  makePostForm.target = 'iframe_makePost';
  makePostForm.style.marginBottom = '20px';
  makePostForm.style.display = 'flex';
  makePostForm.style.gap = '10px';

  const postInput = document.createElement('input');
  postInput.type = 'text';
  postInput.name = 'post_text';
  postInput.placeholder = 'Write a Post...';
  postInput.required = true;
  postInput.style.flex = '1';
  postInput.style.padding = '8px';

  const submitPostBtn = document.createElement('button');
  submitPostBtn.type = 'submit';
  submitPostBtn.textContent = 'Make a Post';
  submitPostBtn.style.padding = '8px 12px';
  submitPostBtn.style.cursor = 'pointer';

  makePostForm.appendChild(postInput);
  makePostForm.appendChild(submitPostBtn);

  const container = document.createElement('div');

  function buildHierarchy(flatNodes) {
    const map = {};
    const roots = [];
    flatNodes.forEach(node => (map[node.id] = node));
    flatNodes.forEach(node => {
      const parent = map[node.parent_id];
      if (parent) parent.children.push(node);
      else roots.push(node);
    });
    return roots;
  }

  function createNodeDiv(node) {
    const nodeDiv = document.createElement('div');
    nodeDiv.style.border = '1px solid #aaa';
    nodeDiv.style.padding = '6px';
    nodeDiv.style.margin = '6px';
    nodeDiv.style.borderRadius = '6px';
    nodeDiv.style.backgroundColor = '#f9f9f9';

    let currentUpdown = node.updown;

    const textSpan = document.createElement('span');
    textSpan.textContent = `${node.username}: ${node.text} (${currentUpdown})`;
    textSpan.style.fontWeight = 'bold';
    textSpan.style.color = '#0066cc';
    nodeDiv.appendChild(textSpan);
    nodeDiv.appendChild(document.createElement('br'));

    function sendVote(url) {
      const iframe = document.createElement('iframe');
      iframe.style.display = 'none';
      iframe.src = url;
      document.body.appendChild(iframe);
      iframe.onload = () => {
        setTimeout(() => {
          try { document.body.removeChild(iframe); } catch (e) {}
        }, 1000);
      };
    }

    // Upvote button
    const upBtn = document.createElement('button');
    upBtn.textContent = 'Upvote';
    upBtn.onclick = () => {
      currentUpdown += 1;
      textSpan.textContent = `${node.username}: ${node.text} (${currentUpdown})`;
      const url = `/upvote?id=${encodeURIComponent(node.id)}&subreddit=${encodeURIComponent(subreddit)}`;
      sendVote(url);
    };

    // Downvote button
    const downBtn = document.createElement('button');
    downBtn.textContent = 'Downvote';
    downBtn.onclick = () => {
      currentUpdown -= 1;
      textSpan.textContent = `${node.username}: ${node.text} (${currentUpdown})`;
      const url = `/downvote?id=${encodeURIComponent(node.id)}&subreddit=${encodeURIComponent(subreddit)}`;
      sendVote(url);
    };

    nodeDiv.appendChild(upBtn);
    nodeDiv.appendChild(downBtn);

    // Comment form
    const form = document.createElement('form');
    form.method = 'POST';
    form.action = '/addComment';
    form.style.marginTop = '6px';

    const commentIframe = document.createElement('iframe');
    commentIframe.name = `iframe_comment_${node.id}`;
    commentIframe.style.display = 'none';
    nodeDiv.appendChild(commentIframe);
    form.target = commentIframe.name;

    const inputBox = document.createElement('input');
    inputBox.type = 'text';
    inputBox.name = 'comment';
    inputBox.placeholder = 'Write a comment...';
    inputBox.required = true;

    const hiddenParent = document.createElement('input');
    hiddenParent.type = 'hidden';
    hiddenParent.name = 'parent_id';
    hiddenParent.value = node.id;

    const hiddenSubreddit2 = document.createElement('input');
    hiddenSubreddit2.type = 'hidden';
    hiddenSubreddit2.name = 'subreddit';
    hiddenSubreddit2.value = subreddit;

    const hiddenUsername2 = document.createElement('input');
    hiddenUsername2.type = 'hidden';
    hiddenUsername2.name = 'username';
    hiddenUsername2.value = currentUser;

    const submitBtn = document.createElement('button');
    submitBtn.type = 'submit';
    submitBtn.textContent = 'Write Comment';

    form.appendChild(inputBox);
    form.appendChild(hiddenParent);
    form.appendChild(hiddenSubreddit2);
    form.appendChild(hiddenUsername2);
    form.appendChild(submitBtn);

    form.onsubmit = e => {
      e.preventDefault();
      const commentText = inputBox.value.trim();
      if (!commentText) return;

      const newNode = {
        id: Date.now().toString(),
        parent_id: node.id,
        username: currentUser,
        updown: 0,
        subreddit: subreddit,
        text: commentText,
        children: []
      };

      const newDiv = createNodeDiv(newNode);
      newDiv.style.marginLeft = '25px';
      nodeDiv.appendChild(newDiv);
      inputBox.value = '';

      const tempForm = document.createElement('form');
      tempForm.method = 'POST';
      tempForm.action = '/addComment';
      tempForm.target = commentIframe.name;
      const inputs = [
        { name: 'parent_id', value: newNode.parent_id },
        { name: 'comment', value: newNode.text },
        { name: 'username', value: newNode.username },
        { name: 'subreddit', value: newNode.subreddit }
      ];
      inputs.forEach(i => {
        const inp = document.createElement('input');
        inp.type = 'hidden';
        inp.name = i.name;
        inp.value = i.value;
        tempForm.appendChild(inp);
      });
      document.body.appendChild(tempForm);
      tempForm.submit();
      document.body.removeChild(tempForm);
    };

    nodeDiv.appendChild(form);
    return nodeDiv;
  }

  function renderTree(nodes, parentContainer) {
    nodes.forEach(node => {
      const nodeDiv = createNodeDiv(node);
      if (node.children.length > 0) {
        renderTree(node.children, nodeDiv);
      }
      parentContainer.appendChild(nodeDiv);
    });
  }

  // Clear body and append in desired order: title -> makePostForm -> (other elements)
  document.body.innerHTML = '';
  document.body.appendChild(title);
  document.body.appendChild(postIframe);
  document.body.appendChild(makePostForm);
  document.body.appendChild(container);

  // render tree if any nodes exist
  const tree = buildHierarchy(nodes);
  renderTree(tree, container);

  // Leave Subreddit button (redirect)
  const leaveBtn = document.createElement('button');
  leaveBtn.textContent = 'Leave Subreddit';
  leaveBtn.style.marginTop = '20px';
  leaveBtn.style.padding = '8px 12px';
  leaveBtn.style.cursor = 'pointer';
  leaveBtn.onclick = () => {
    window.location.href = `/leaveSubreddit?username=${encodeURIComponent(currentUser)}&subreddit=${encodeURIComponent(subreddit)}`;
  };
  document.body.appendChild(leaveBtn);

  // Make Post submission behavior
  makePostForm.onsubmit = e => {
    e.preventDefault();
    const postText = postInput.value.trim();
    if (!postText) return;

    const newPostNode = {
      id: Date.now().toString(),
      parent_id: '0',
      username: currentUser,
      updown: 0,
      subreddit: subreddit,
      text: postText,
      children: []
    };

    const newDiv = createNodeDiv(newPostNode);
    container.appendChild(newDiv);
    postInput.value = '';

    const tempForm = document.createElement('form');
    tempForm.method = 'POST';
    tempForm.action = '/makePost';
    tempForm.target = postIframe.name;
    const inputs = [
      { name: 'subreddit', value: subreddit },
      { name: 'username', value: currentUser },
      { name: 'post_text', value: postText }
    ];
    inputs.forEach(i => {
      const inp = document.createElement('input');
      inp.type = 'hidden';
      inp.name = i.name;
      inp.value = i.value;
      tempForm.appendChild(inp);
    });
    document.body.appendChild(tempForm);
    tempForm.submit();
    document.body.removeChild(tempForm);
  };
}

renderCommentTree();


      
      </script>"

const view_dm_script = "<script>
function processLinks() {
  // Get all <a> elements with both id and username
  const links = Array.from(document.querySelectorAll('a[id][username]'));

  // Sort by id ascending
  links.sort((a, b) => Number(a.id) - Number(b.id));

  // Create container for the displayed messages
  const container = document.createElement('div');
  container.id = 'dm-container';

  for (const link of links) {
    const username = link.getAttribute('username');
    const text = link.textContent;

    const div = document.createElement('div');
    div.textContent = `${username}: ${text}`;
    container.appendChild(div);
  }

  // Input and button
  const input = document.createElement('input');
  input.type = 'text';
  input.placeholder = 'Type your message...';
  input.id = 'dm-input';

  const button = document.createElement('button');
  button.textContent = 'Send DM';

  // Hidden iframe
  const iframe = document.createElement('iframe');
  iframe.name = 'hiddenFrame';
  iframe.style.display = 'none';

  // Form for POST submission
  const form = document.createElement('form');
  form.method = 'POST';
  form.target = 'hiddenFrame';
  form.style.display = 'inline';

  const info = document.getElementById('info');
  const usernameFrom = info.getAttribute('username_from');
  const usernameTo = info.getAttribute('username_to');

  // Add query params to form action
  form.action = `/addDirectMessage?username_from=${encodeURIComponent(usernameFrom)}&username_to=${encodeURIComponent(usernameTo)}`;

  // Hidden input for content
  const hiddenMessage = document.createElement('input');
  hiddenMessage.type = 'hidden';
  hiddenMessage.name = 'content';
  form.appendChild(hiddenMessage);

  button.addEventListener('click', (event) => {
    event.preventDefault(); // don't navigate
    const message = input.value.trim();
    if (message === '') return;

    // Update hidden field and submit
    hiddenMessage.value = message;
    form.submit();

    // Append message locally
    const newDiv = document.createElement('div');
    newDiv.textContent = `${usernameFrom}: ${message}`;
    container.appendChild(newDiv);

    // Clear input
    input.value = '';
  });

  // Assemble layout
  form.appendChild(button);
  document.body.appendChild(container);
  document.body.appendChild(input);
  document.body.appendChild(form);
  document.body.appendChild(iframe);
}

// Run when DOM is ready
document.addEventListener('DOMContentLoaded', processLinks);
</script>"

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
    user_dm_db: dict.Dict(
      String,
      dict.Dict(String, List(#(String, String, Int, Int))),
    ),
    user_login_db: dict.Dict(String, String),
    user_subreddit_db: dict.Dict(String, List(String)),
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
  GetPosts(process.Subject(List(#(Int, Int, String, Int, String))), String)
  GetDMList(
    process.Subject(
      dict.Dict(String, dict.Dict(String, List(#(String, String, Int, Int)))),
    ),
  )
  GetSubredditsSubscribed(process.Subject(List(String)), String)
  GetKarma(process.Subject(Int), String)
  GetUserList(process.Subject(List(String)))
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
        state.user_subreddit_db,
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
        state.user_subreddit_db,
      ))
    }
    CreateSubReddit(subreddit_name) -> {
      let subreddit_user_db =
        dict.insert(state.subreddit_user_db, subreddit_name, [])

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
        state.user_subreddit_db,
      ))
    }
    JoinSubReddit(subreddit_name, username) -> {
      let subreddit_db =
        add_to_list_in_dict(state.subreddit_user_db, subreddit_name, username)

      let user_subreddit_db =
        add_user_to_subreddit(username, subreddit_name, state.user_subreddit_db)

      // echo user_subreddit_db

      // echo user_subreddit_db
      // echo user_subreddit_db

      actor.continue(State(
        state.internal,
        state.engine_actor,
        state.users_db,
        subreddit_db,
        state.subreddit_comment_db,
        state.user_karma,
        state.user_dm_db,
        state.user_login_db,
        user_subreddit_db,
      ))
    }
    LeaveSubReddit(subreddit_name, username) -> {
      let subreddit_db =
        remove_from_list_in_dict(
          state.subreddit_user_db,
          subreddit_name,
          username,
        )

      let user_subreddit_db =
        remove_user_from_subreddit(
          username,
          subreddit_name,
          state.user_subreddit_db,
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
        user_subreddit_db,
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
        state.user_subreddit_db,
      ))
    }
    Comment(subreddit_name, username, parent_comment_id, comment) -> {
      let #(current_comment_id, current_dm_id) = state.internal
      let current_comment_id = current_comment_id + 1
      let subreddit_comment_db =
        add_comment(state.subreddit_comment_db, subreddit_name, #(
          0,
          current_comment_id,
          comment,
          parent_comment_id,
          username,
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
        state.user_subreddit_db,
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

      // echo comment_id
      // echo post_username

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
        state.user_subreddit_db,
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
        state.user_subreddit_db,
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

      // echo user_dm_db
      // process.sleep(5000)

      // let user_dm_db =
      //   add_dm2(
      //     to_username,
      //     from_username,
      //     content,
      //     current_dm_id,
      //     parent_comment_id,
      //     user_dm_db,
      //   )
      // echo user_dm_db
      // process.sleep(5000)

      // let user_dm_db =
      //   add_dm(
      //     to_username,
      //     from_username,
      //     content,
      //     current_dm_id,
      //     parent_comment_id,
      //     user_dm_db,
      //   )

      // echo user_dm_db
      // let user_dm_db =
      //   add_dm(
      //     from_username,
      //     to_username,
      //     content,
      //     current_dm_id,
      //     parent_comment_id,
      //     user_dm_db,
      //   )
      // echo user_dm_db
      // echo dict.get(user_dm_db, "Griz")
      // echo to_username

      actor.continue(State(
        #(current_comment_id, current_dm_id),
        state.engine_actor,
        state.users_db,
        state.subreddit_user_db,
        state.subreddit_comment_db,
        state.user_karma,
        user_dm_db,
        state.user_login_db,
        state.user_subreddit_db,
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
        state.user_subreddit_db,
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
        state.user_subreddit_db,
      ))
    }
    GetSubreddits(main_handle) -> {
      process.send(main_handle, state.subreddit_user_db)

      actor.continue(state)
    }
    GetPosts(main_handle, subreddit_name) -> {
      // process.send(main_handle, )

      let result = dict.get(state.subreddit_comment_db, subreddit_name)

      let posts = case result {
        Ok(result) -> result
        Error(_) -> []
      }
      process.send(main_handle, posts)

      actor.continue(state)
    }
    GetDMList(main_handle) -> {
      process.send(main_handle, state.user_dm_db)

      actor.continue(state)
    }
    GetSubredditsSubscribed(main_handle, username) -> {
      let result = dict.get(state.user_subreddit_db, username)
      let subreddits = case result {
        Ok(result) -> result
        Error(_) -> []
      }

      // echo state.user_subreddit_db
      process.send(main_handle, subreddits)

      actor.continue(state)
    }
    GetKarma(main_handle, username) -> {
      let result = dict.get(state.user_karma, username)

      let karma = case result {
        Ok(result) -> result
        Error(_) -> 0
      }

      process.send(main_handle, karma)

      actor.continue(state)
    }
    GetUserList(main_handle) -> {
      let user_list = dict.keys(state.users_db)

      process.send(main_handle, user_list)

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
  let user_subreddit_db = dict.new()

  let assert Ok(engine_actor) =
    actor.new(State(
      #(10, 10),
      [],
      user_db,
      subreddit_user_db,
      subreddit_comment_db,
      user_karma_db,
      user_dm_db,
      user_login_db,
      user_subreddit_db,
    ))
    |> actor.on_message(handle_message)
    |> actor.start

  let engine_handle = engine_actor.data

  process.send(engine_handle, RegisterAccount("user", "pass"))
  process.send(engine_handle, RegisterAccount("Griz", "pass"))
  process.send(engine_handle, CreateSubReddit("Raves"))
  process.send(engine_handle, Post("Raves", "Griz", "Raves are cool"))
  process.send(engine_handle, JoinSubReddit("Raves", "user"))
  process.send(engine_handle, EngineDm("Griz", "user", "Hey", 0))
  process.send(engine_handle, EngineDm("user", "Griz", "Hello", 0))
  process.send(engine_handle, EngineDm("user", "Griz", "What's up?", 0))

  logging.configure()
  logging.set_level(logging.Debug)
  //TODO
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
        ["viewSubreddit"] -> view_subreddit(req, engine_handle)
        ["login"] -> login(req, engine_handle)
        ["upvote"] -> upvote(req, engine_handle)
        ["downvote"] -> downvote(req, engine_handle)
        ["addComment"] -> create_comment(req, engine_handle)
        ["makePost"] -> make_post(req, engine_handle)
        ["leaveSubreddit"] -> leave_subreddit(req, engine_handle)
        ["viewDirectMessages"] -> view_dms(req, engine_handle)
        ["home"] -> home(req, engine_handle)
        ["viewDirectMessage"] -> view_dm(req, engine_handle)
        ["addDirectMessage"] -> create_dm(req, engine_handle)

        _ -> not_found
      }
    }
    |> mist.new
    |> mist.bind("0.0.0.0")
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
  io.println("Got GET Request /createAccount")
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

  io.println("Got GET Request /login")

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
         <a href='/home?username=" <> username <> "'>Home</a>
         <a href='/getSubreddits?username=" <> username <> "'>Join Subreddit</a>
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
  io.println("Got GET Request /getSubreddits")
  // echo keys

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

  io.println("Got GET Request /createSubreddit")
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

fn create_dm(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  let assert Ok(body) = mist.read_body(req, 10_000)

  let query = case req.query {
    option.Some(q) -> q
    option.None -> ""
  }

  //echo query

  let assert Ok(body) = mist.read_body(req, 10_000)

  let result = bit_array.to_string(body.body)

  let body_string = case result {
    Ok(result) -> result
    Error(_) -> "Error"
  }

  let query_fields = string.split(query, "&")
  let body_fields = string.split(body_string, "=")
  let username_from =
    nth_string(string.split(nth_string(query_fields, 0), "="), 1)
  let username_to =
    nth_string(string.split(nth_string(query_fields, 1), "="), 1)

  let content = nth_string(body_fields, 1)

  process.send(engine_handle, EngineDm(username_from, username_to, content, 0))
  // echo body_string
  // echo query
  // echo fields
  // echo username

  io.println("Got POST Request /addDirectMessage/" <> username_from)

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(index)))
}

fn view_subreddit(
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
  let username_poster = nth_string(string.split(nth_string(fields, 1), "="), 1)

  // echo username_poster
  io.println("Got GET Request /viewSubreddit/" <> subreddit_name)
  process.send(engine_handle, JoinSubReddit(subreddit_name, username_poster))

  // echo subreddit_name

  let main_handle = process.new_subject()

  process.send(engine_handle, GetPosts(main_handle, subreddit_name))

  let result = process.receive(main_handle, 100_000)

  let posts = case result {
    Ok(result) -> result
    Error(_) -> []
  }

  // echo posts

  let a_list =
    list.map(posts, fn(post) {
      let #(updown, comment_id, username, parent_comment_id, comment) = post

      "<a hidden id='"
      <> int.to_string(comment_id)
      <> "' parent_id='"
      <> int.to_string(parent_comment_id)
      <> "' username='"
      <> username
      <> "' updown='"
      <> int.to_string(updown)
      <> "' subreddit='"
      <> subreddit_name
      <> "'>"
      <> comment
      <> "</a>"
    })

  let a_list = string.concat(a_list)

  // echo a_list

  let page_body =
    "<html><body>"
    <> a_list
    <> "<p id='username' username='"
    <> username_poster
    <> "' subreddit='"
    <> subreddit_name
    <> "'> </p>"
    <> view_script
    <> "<div> <a href='/home?username="
    <> username_poster
    <> "'>Home<a> </div>"
    <> "</body></html>"

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(page_body)))
}

fn view_dms(
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
  let body_top = "<html><body>"
  let body_bottom = "</body></html>"

  let fields = string.split(query, "=")
  let username = nth_string(fields, 1)

  let main_handle = process.new_subject()

  process.send(engine_handle, GetUserList(main_handle))

  let result = process.receive(main_handle, 100_000)

  let user_list = case result {
    Ok(result) -> result
    Error(_) -> []
  }

  // echo user_list
  io.println("Got GET Request /viewDirectMessages/" <> username)
  let a_list =
    list.map(user_list, fn(user) {
      "<div> <a href='/viewDirectMessage?usernameto="
      <> user
      <> "&usernamefrom="
      <> username
      <> "'>"
      <> user
      <> " </a></div>"
    })
  let a_list = string.concat(a_list)

  let dm_page = body_top <> a_list <> body_bottom

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(dm_page)))
}

fn view_dm(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  let assert Ok(body) = mist.read_body(req, 10_000)

  let query = case req.query {
    option.Some(q) -> q
    option.None -> ""
  }

  let fields = string.split(query, "&")
  let username_to = nth_string(string.split(nth_string(fields, 0), "="), 1)
  let username_from = nth_string(string.split(nth_string(fields, 1), "="), 1)

  io.println("Got GET Request /viewDirectMessage/" <> username_from)

  // echo query
  let main_handle = process.new_subject()

  let fields = string.split(query, "&")
  let username_to = nth_string(string.split(nth_string(fields, 0), "="), 1)
  let username_from = nth_string(string.split(nth_string(fields, 1), "="), 1)

  process.send(engine_handle, GetDMList(main_handle))

  let result = process.receive(main_handle, 100_000)
  let default = dict.new()
  let default2 = dict.new()

  let dm_db = case result {
    Ok(result) -> result
    Error(_) -> default
  }

  let result = dict.get(dm_db, username_from)

  let user_from_db = case result {
    Ok(result) -> result
    Error(_) -> default2
  }

  let result = dict.get(user_from_db, username_to)

  let user_from_list = case result {
    Ok(result) -> result
    Error(_) -> []
  }

  let result = dict.get(dm_db, username_to)

  let user_to_db = case result {
    Ok(result) -> result
    Error(_) -> default2
  }

  let result = dict.get(user_to_db, username_from)

  let user_to_list = case result {
    Ok(result) -> result
    Error(_) -> []
  }
  // echo user_to_list
  // echo user_from_list

  let body_top = "<html><body>"
  let body_bottom = "</body></html>"

  let p_element =
    "<p hidden id='info' username_from='"
    <> username_from
    <> "' username_to='"
    <> username_to
    <> "'> </p>"

  let from_a_list =
    list.map(user_from_list, fn(entry) {
      let #(dm_user, content, id, parent_id) = entry

      "<a hidden id='"
      <> int.to_string(id)
      <> "' username='"
      <> dm_user
      <> "'>"
      <> content
      <> "</a>"
    })
  let from_a_list = string.concat(from_a_list)

  let to_a_list =
    list.map(user_to_list, fn(entry) {
      let #(dm_user, content, id, parent_id) = entry

      "<a hidden id='"
      <> int.to_string(id)
      <> "' username='"
      <> dm_user
      <> "'>"
      <> content
      <> "</a>"
    })
  let to_a_list = string.concat(to_a_list)

  let dm_page =
    body_top
    <> p_element
    <> from_a_list
    <> to_a_list
    <> view_dm_script
    <> body_bottom

  // let result = dict.get(dm_db, username_to)

  // let user_from_db = case result {
  //   Ok(result) -> result
  //   Error(_) -> default2
  // }

  // let result = dict.get(user_from_db, username_from)

  // let user_to_db = case result {
  //   Ok(result) -> result
  //   Error(_) -> []
  // }
  // echo user_to_db
  // echo user_from_db

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(dm_page)))
}

fn home(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  //let assert Ok(body) = mist.read_body(req, 10_000)

  let query = case req.query {
    option.Some(q) -> q
    option.None -> ""
  }

  let body_top = "<html><body>"
  let body_bottom = "</body></html>"

  let main_handle = process.new_subject()

  // process.send(engine_handle,GetSubredditsSubscribed(main_handle,))

  let fields = string.split(query, "=")
  let username = nth_string(fields, 1)

  process.send(engine_handle, GetSubredditsSubscribed(main_handle, username))

  let result = process.receive(main_handle, 100_000)

  let subreddits = case result {
    Ok(result) -> result
    Error(_) -> []
  }

  io.println("Got GET Request /home")

  let main_handle = process.new_subject()
  process.send(engine_handle, GetKarma(main_handle, username))

  let result = process.receive(main_handle, 100_000)

  let karma = case result {
    Ok(result) -> result
    Error(_) -> 0
  }

  let a_list =
    list.map(subreddits, fn(subreddit) {
      "<a href=/viewSubreddit?subreddit="
      <> subreddit
      <> "&username="
      <> username
      <> ">"
      <> subreddit
      <> "</a>\n"
    })
  let a_list = string.concat(a_list)

  let home_page =
    body_top
    <> "<div> <h1> Karma </h1> "
    <> "<h3>"
    <> int.to_string(karma)
    <> "</h3> </div>"
    <> "<div> <h1>Subscribed Subreddits</h1>"
    <> a_list
    <> "</div>"
    <> "<div> <h1>Join Subreddit </h1>"
    <> "<a href='/getSubreddits?username="
    <> username
    <> "'>Join Subreddit</a></div>"
    <> "<div> <h1>Create Subreddit</h1>"
    <> "<a href='/createSubreddit?username="
    <> username
    <> "'>Create Subreddit</a>"
    <> "</div>"
    <> "<div> <h1>View DMs</h1>"
    <> "<a href='/viewDirectMessages?username="
    <> username
    <> "'> View Dms</a>"
    <> body_bottom

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(home_page)))
}

fn upvote(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  //let assert Ok(body) = mist.read_body(req, 10_000)

  let query = case req.query {
    option.Some(q) -> q
    option.None -> ""
  }

  let fields = string.split(query, "&")

  let id = nth_string(string.split(nth_string(fields, 0), "="), 1)
  let subreddit_name = nth_string(string.split(nth_string(fields, 1), "="), 1)

  let result = int.base_parse(id, 10)

  let id = case result {
    Ok(result) -> result
    Error(_) -> 0
  }
  io.println(
    "Got POST Request /upvote/" <> subreddit_name <> "/" <> int.to_string(id),
  )

  //process.send(engine_handle, JoinSubReddit(subreddit_name, username))

  process.send(engine_handle, UpVote(subreddit_name, id))

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(upvote_page)))
}

fn downvote(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  //let assert Ok(body) = mist.read_body(req, 10_000)

  let query = case req.query {
    option.Some(q) -> q
    option.None -> ""
  }

  let fields = string.split(query, "&")

  let id = nth_string(string.split(nth_string(fields, 0), "="), 1)
  let subreddit_name = nth_string(string.split(nth_string(fields, 1), "="), 1)

  let result = int.base_parse(id, 10)

  let id = case result {
    Ok(result) -> result
    Error(_) -> 0
  }
  io.println(
    "Got POST Request /downvote/" <> subreddit_name <> "/" <> int.to_string(id),
  )

  //process.send(engine_handle, JoinSubReddit(subreddit_name, username))

  process.send(engine_handle, DownVote(subreddit_name, id))

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(downvote_page)))
}

fn create_comment(
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

  let parent_id = nth_string(string.split(nth_string(fields, 0), "="), 1)
  let username = nth_string(string.split(nth_string(fields, 1), "="), 1)
  let comment = nth_string(string.split(nth_string(fields, 2), "="), 1)
  let subreddit_name = nth_string(string.split(nth_string(fields, 3), "="), 1)

  let result = int.base_parse(parent_id, 10)

  let parent_id = case result {
    Ok(result) -> result
    Error(_) -> 0
  }

  io.println(
    "Got POST Request /addComment/"
    <> subreddit_name
    <> "/"
    <> int.to_string(parent_id),
  )
  process.send(
    engine_handle,
    Comment(subreddit_name, username, parent_id, comment),
  )

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(index)))
}

fn make_post(
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

  let subreddit_name = nth_string(string.split(nth_string(fields, 0), "="), 1)
  let username = nth_string(string.split(nth_string(fields, 1), "="), 1)
  let post_text = nth_string(string.split(nth_string(fields, 2), "="), 1)

  process.send(engine_handle, Post(subreddit_name, username, post_text))

  io.println("Got POST Request /makePost/" <> subreddit_name)
  // let result = int.base_parse(parent_id, 10)

  // let parent_id = case result {
  //   Ok(result) -> result
  //   Error(_) -> 0
  // }

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(index)))
}

fn leave_subreddit(
  req: Request(Connection),
  engine_handle: process.Subject(Message),
) -> Response(ResponseData) {
  // Parse form data from the request body
  // let assert Ok(body) = mist.read_body(req, 10_000)

  let query = case req.query {
    option.Some(q) -> q
    option.None -> ""
  }

  let fields = string.split(query, "&")

  let username = nth_string(string.split(nth_string(fields, 0), "="), 1)
  let subreddit_name = nth_string(string.split(nth_string(fields, 1), "="), 1)

  let leave_subreddit_page = "<html>
       <body>
         <h1>Left Subreddit 
        " <> subreddit_name <> "
        </h1>
        <a href='/home?username=" <> username <> "'>Home</a>
       </body>
     </html>"

  io.println("Got GET Request /leaveSubreddit/" <> subreddit_name)
  process.send(engine_handle, LeaveSubReddit(subreddit_name, username))
  // let result = bit_array.to_string(body.body)

  // let body_string = case result {
  //   Ok(result) -> result
  //   Error(_) -> "Error"
  // }

  // let fields = string.split(body_string, "&")

  // let subreddit_name = nth_string(string.split(nth_string(fields, 0), "="), 1)
  // let username = nth_string(string.split(nth_string(fields, 1), "="), 1)
  // let post_text = nth_string(string.split(nth_string(fields, 2), "="), 1)

  // process.send(engine_handle, Post(subreddit_name, username, post_text))

  // let result = int.base_parse(parent_id, 10)

  // let parent_id = case result {
  //   Ok(result) -> result
  //   Error(_) -> 0
  // }

  response.new(200)
  |> response.prepend_header("my-value", "abc")
  |> response.prepend_header("my-value", "123")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(leave_subreddit_page)))
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
  d: dict.Dict(String, dict.Dict(String, List(#(String, String, Int, Int)))),
) -> dict.Dict(String, dict.Dict(String, List(#(String, String, Int, Int)))) {
  dict.upsert(d, a, fn(maybe_inner) {
    // If outer dict (key a) exists, use it, else start new inner dict
    let inner = case maybe_inner {
      option.Some(existing_inner) -> existing_inner
      option.None -> dict.new()
    }
    // echo #(a, c, e, f)
    // Update the inner dict at key b
    let updated_inner =
      dict.upsert(inner, b, fn(maybe_list) {
        case maybe_list {
          option.Some(existing_list) ->
            list.append(existing_list, [#(a, c, e, 0)])
          option.None -> [#(a, c, e, f)]
        }
      })

    updated_inner
  })
}

pub fn add_dm2(
  from_username: String,
  to_username: String,
  content: String,
  current_dm_id: Int,
  parent_dm_id: Int,
  user_dm_db: dict.Dict(
    String,
    dict.Dict(String, List(#(String, String, Int, Int))),
  ),
) -> dict.Dict(String, dict.Dict(String, List(#(String, String, Int, Int)))) {
  let message = #(from_username, content, current_dm_id, parent_dm_id)

  // echo message
  // Get the sender's message dict (or an empty one)
  let from_map =
    dict.get(user_dm_db, from_username)
    |> result.unwrap(dict.new())

  // Get the list of DMs to this recipient (or empty list)
  let dm_list =
    dict.get(from_map, to_username)
    |> result.unwrap([])

  // Add the new message to the list
  let updated_list = list.append(dm_list, [message])

  // Update the inner dict with the new list
  let updated_inner = dict.insert(from_map, to_username, updated_list)

  // Update the outer dict
  dict.insert(user_dm_db, from_username, updated_inner)
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

// Helper to check if a list contains a value
fn contains(lst: List(String), value: String) -> Bool {
  case lst {
    [] -> False
    [head, ..tail] ->
      case head == value {
        True -> True
        False -> contains(tail, value)
      }
  }
}

pub fn add_user_to_subreddit(
  key: String,
  value: String,
  d: dict.Dict(String, List(String)),
) -> dict.Dict(String, List(String)) {
  // Get the existing list at key, or empty list if key not present
  let existing_list = case dict.get(d, key) {
    Ok(lst) -> lst
    Error(_) -> []
  }

  // Only append value if not already present
  let new_list = case contains(existing_list, value) {
    True -> existing_list
    False -> list.append(existing_list, [value])
  }

  dict.insert(d, key, new_list)
}

fn remove_from_list(lst: List(String), value: String) -> List(String) {
  case lst {
    [] -> []
    [head, ..tail] ->
      case head == value {
        True -> remove_from_list(tail, value)
        False -> [head, ..remove_from_list(tail, value)]
      }
  }
}

pub fn remove_user_from_subreddit(
  key: String,
  value: String,
  d: dict.Dict(String, List(String)),
) -> dict.Dict(String, List(String)) {
  // Get the existing list at the key, or empty list if key not present
  let existing_list = case dict.get(d, key) {
    Ok(lst) -> lst
    Error(_) -> []
  }

  // Remove value from the list
  let new_list = remove_from_list(existing_list, value)

  // Insert the updated list back into the dictionary
  dict.insert(d, key, new_list)
}
