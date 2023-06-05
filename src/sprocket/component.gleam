import gleam/dynamic
import gleam/otp/actor
import gleam/erlang/process.{Subject}
import sprocket/socket.{
  Component, Effect, EffectCleanup, EffectTrigger, Element, FunctionalComponent,
  Socket,
}

pub fn component(c: FunctionalComponent(p), props: p) -> Element {
  // // This function wrapper will not work since we need to compare the original function
  // // when computing the diff and this will create a different function on every render
  // let component = fn(socket: Socket, props: Dynamic) -> #(Socket, List(Element)) {
  //   let props = dynamic.unsafe_coerce(props)
  //   fc.component(socket, props)
  // }

  // Instead, we will just use dynamic.unsafe_coerce to coerce the function to the correct type
  let component =
    c
    |> dynamic.from()
    |> dynamic.unsafe_coerce()

  let props =
    props
    |> dynamic.from()

  Component(component, props)
}

pub fn render(socket, elements) -> #(Socket, List(Element)) {
  #(socket, elements)
}

pub type Updater(msg) =
  fn(msg) -> Nil

pub type State(model, msg) {
  State(m: model, d: Updater(msg))
}

type Reducer(model, msg) =
  fn(model, msg) -> model

type StateOrDispatchReducer(model, msg) {
  StateReducer(reply_with: Subject(model))
  DispatchReducer(r: Reducer(model, msg), m: msg)
}

pub fn reducer(
  socket: Socket,
  initial: model,
  reducer: Reducer(model, msg),
  cb: fn(Socket, State(model, msg)) -> #(Socket, List(Element)),
) -> #(Socket, List(Element)) {
  let Socket(render_update: render_update, ..) = socket

  // creates an actor process for a reducer that handles two types of messages:
  //  1. StateReducer msg, which simply returns the state of the reducer
  //  2. DispatchReducer msg, which will update the reducer state when a dispatch is triggered
  let reducer_init = fn() {
    let assert Ok(actor) =
      actor.start(
        initial,
        fn(message: StateOrDispatchReducer(model, msg), state: model) -> actor.Next(
          model,
        ) {
          case message {
            StateReducer(reply_with) -> {
              process.send(reply_with, state)
              actor.Continue(state)
            }

            DispatchReducer(r, m) -> {
              r(state, m)
              |> actor.Continue()
            }
          }
        },
      )

    dynamic.from(actor)
  }

  let #(socket, dyn_reducer_actor) =
    socket.fetch_or_create_reducer(socket, reducer_init)

  // we dont know what types of reducer messages a component will implement so the best
  // we can do is store the actors as dynamic and coerce them back when updating
  let reducer_actor = dynamic.unsafe_coerce(dyn_reducer_actor)

  // get the current state of the reducer
  let state = process.call(reducer_actor, StateReducer(_), 10)

  // create a dispatch function for updating the reducer's state and triggering a render update
  let dispatch = fn(msg) -> Nil {
    // TODO: we might need to wait for the reducer to finish updating before triggering a render update
    actor.send(reducer_actor, DispatchReducer(r: reducer, m: msg))
    render_update()

    Nil
  }

  cb(socket, State(state, dispatch))
}

pub fn effect(
  socket: Socket,
  effect_fn: fn() -> EffectCleanup,
  trigger: EffectTrigger,
  cb: fn(Socket) -> #(Socket, List(Element)),
) -> #(Socket, List(Element)) {
  let socket = socket.push_hook(socket, Effect(effect_fn, trigger))

  cb(socket)
}
