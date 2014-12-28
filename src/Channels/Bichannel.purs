module Channels.Bichannel 
  ( Bichannel(..)
  , Bisink(..)
  , Bisource(..)
  , Biworkflow(..)
  , Downstream(..)
  , Upstream(..)
  , awaitDown
  , awaitUp
  , runBiworkflow
  , stack
  , toWorkflow
  , toDownstream
  , toUpstream
  , unDownstream
  , unUpstream
  , yieldDown
  , yieldUp
  ) where 

  import Data.Either(Either(..), either)
  import Data.Tuple(Tuple(..))
  import Data.Lazy(Lazy(..), force)
  import Data.Monoid
  import Data.Profunctor(Profunctor, dimap)
  import Control.Lazy(defer1)

  import Channels.Core
  import Channels.Stream(Stream(..), unStream)

  -- | A bidirectional channel, which has both upstream and downstream channels
  -- | of communication.
  type Bichannel a a' b b' f r = Channel (Either a b) (Either a' b') f r
  
  -- | A bisource, defined as a bichannel that never emits upstream values or 
  -- | awaits downstream values. Since we can't enforce that using the type 
  -- | system, we loosen the definition to a bichannel that emits unit for 
  -- | upstream and awaits unit from downstream.
  type Bisource f a b r = Bichannel Unit a b Unit f r

  -- | A bisink, defined as a bichannel that never emits downstream values or 
  -- | awaits upstream values. Since we can't enforce that using the type 
  -- | system, we loosen the definition to a bichannel that emits unit for
  -- | downstream and awaits unit from upstream.
  type Bisink f a b r = Bichannel a Unit Unit b f r

  type Biworkflow f r = Bichannel Unit Unit Unit Unit f r

  newtype Upstream a f r b b' = Upstream (Bichannel a a b b' f r)

  newtype Downstream b f r a a' = Downstream (Bichannel a a' b b f r)

  unUpstream :: forall a f r b b'. Upstream a f r b b' -> Bichannel a a b b' f r
  unUpstream (Upstream c) = c

  unDownstream :: forall b f r a a'. Downstream b f r a a' -> Bichannel a a' b b f r
  unDownstream (Downstream c) = c

  toUpstream :: forall a f r b b'. (Functor f) => Stream f r b b' -> Upstream a f r b b'
  toUpstream (Stream c) = Upstream (loop' c)
    where loop' (Yield o c q) = Yield (Right o) (loop' c) q
          loop' c0 @ (Await h q) = Await (either (\a -> Yield (Left a) (loop' c0) q) (\b -> loop' (h b))) q
          loop' (ChanX   x q) = ChanX (loop' <$> x) q
          loop' (ChanZ     z) = ChanZ (loop' <$> z)
          loop' (Stop      r) = Stop r

  toDownstream :: forall b f r a a'. (Functor f) => Stream f r a a' -> Downstream b f r a a'
  toDownstream (Stream c) = Downstream (loop' c)
    where loop' (Yield o c q) = Yield (Left o) (loop' c) q
          loop' c0 @ (Await h q) = Await (either (\a -> loop' (h a)) (\b -> Yield (Right b) (loop' c0) q)) q
          loop' (ChanX   x q) = ChanX (loop' <$> x) q
          loop' (ChanZ     z) = ChanZ (loop' <$> z)
          loop' (Stop      r) = Stop r

  reflect :: forall a a' b b' f r. (Applicative f) => Bichannel a a' b b' f r -> Bichannel b b' a a' f r
  reflect c = unStream (dimap (either Right Left) (either Right Left) (Stream c))

  -- | Using the specified terminator, awaits a downstream value and passes 
  -- | through all upstream values.
  awaitDown :: forall a a' b f r. (Applicative f) => Effectable f r -> (a -> Bichannel a a' b b f r) -> Bichannel a a' b b f r
  awaitDown q f = await q g
    where 
      g (Left a)  = f a
      g (Right b) = yieldUp q b

  -- | Using the specified terminator, awaits an upstream value and passes 
  -- | through all downstream values.
  awaitUp :: forall a b b' f r. (Applicative f) => Effectable f r -> (b -> Bichannel a a b b' f r) -> Bichannel a a b b' f r
  awaitUp q f = await q g
    where 
      g (Left a)  = yieldDown q a 
      g (Right b) = f b

  -- | Using the specified terminator, emits a downstream value.
  yieldDown :: forall a a' b b' f r. (Applicative f) => Effectable f r -> a' -> Bichannel a a' b b' f r
  yieldDown q a' = yield q (Left a')

  -- | Using the specified terminator, emits an upstream value.
  yieldUp :: forall a a' b b' f r. (Applicative f) => Effectable f r -> b' -> Bichannel a a' b b' f r
  yieldUp q b' = yield q (Right b')

  -- | Stacks one bichannel on top of another. Note that if one bichannel 
  -- | terminates before the other, the second will be forcibly terminated.
  -- | 
  -- | Laziness is introduced when the two channels pass messages between each
  -- | other. This allows channels to be stacked even when all they do is 
  -- | forever pass each other messages (e.g. stacking a source on a sink).
  stack :: forall a a' a'' b b' b'' f r r'. (Applicative f) => Bichannel a a' b' b'' f r -> Bichannel a' a'' b b' f r' -> Bichannel a a'' b b'' f (Tuple r r')
  stack (Stop r1) c2                 = stop' (Tuple r1 <$> runEffectable (terminate c2))
  stack c1 (Stop r2)                 = stop' (flip Tuple r2 <$> runEffectable (terminate c1))
  stack (Yield (Right b'') c1 q1) c2 = Yield (Right b'') (c1 `stack` c2) (defer1 \_ -> (Tuple <$> q1 <*> terminate c2))
  stack c1 (Yield (Left a'') c2 q2)  = Yield (Left  a'') (c1 `stack` c2) (defer1 \_ -> (Tuple <$> terminate c1 <*> q2))
  stack (ChanX fc1 q1) c2            = ChanX (flip stack c2 <$> fc1)     (defer1 \_ -> (Tuple <$> q1 <*> terminate c2))  
  stack (ChanZ z1) c2                = ChanZ (flip stack c2 <$> z1)
  stack c1 (ChanX fc2 q2)            = ChanX (stack c1 <$> fc2)          (defer1 \_ -> (Tuple <$> terminate c1 <*> q2))
  stack c1 (ChanZ z2)                = ChanZ (stack c1 <$> z2)  
  stack (Await f1 q1) (Yield (Right b') c2 q2) = defer1 \_ -> f1 (Right b') `stack` c2
  stack (Yield (Left a') c1 q1) (Await f2 q2)  = defer1 \_ -> c1 `stack` f2 (Left a')

  toWorkflow :: forall f r. (Applicative f) => Biworkflow f r -> Workflow f r
  toWorkflow c = unStream (dimap Left (const unit) (Stream c))

  runBiworkflow :: forall f r. (Monad f) => Biworkflow f r -> f r
  runBiworkflow = toWorkflow >>> runWorkflow

  instance semigroupoidUpstream :: (Applicative f, Semigroup r) => Semigroupoid (Upstream a f r) where
    (<<<) (Upstream c1) (Upstream c2) = Upstream $ (\(Tuple r r') -> r <> r') <$> (c1 `stack` c2)

  instance categoryUpstream :: (Applicative f, Monoid r) => Category (Upstream a f r) where
    id = toUpstream id

  instance profunctorUpstream :: (Applicative f) => Profunctor (Upstream a f r) where
    dimap f g (Upstream c) = Upstream (dimap' c)
      where dimap' (Yield e c q) = Yield (g <$> e) (dimap' c) q
            -- dimap' (Await   h q) = Await (\e -> h (f <$> e)) q
            dimap' (ChanX   x q) = ChanX (dimap' <$> x) q
            dimap' (ChanZ     z) = ChanZ (dimap' <$> z)
            dimap' (Stop      r) = Stop r

  instance semigroupoidDownstream :: (Applicative f, Semigroup r) => Semigroupoid (Downstream b f r) where
    (<<<) (Downstream c1) (Downstream c2) = Downstream $ (\(Tuple r r') -> r' <> r) <$> (c2 `stack` c1)

  instance categoryDownstream :: (Applicative f, Monoid r) => Category (Downstream b f r) where
    id = toDownstream id

  instance profunctorDownstream :: (Applicative f) => Profunctor (Downstream b f r) where
    dimap f g (Downstream c) = Downstream (dimap' c)
      where dimap' (Yield e c q) = Yield (either (g >>> Left) Right e) (dimap' c) q
            -- dimap' (Await   h q) = Await (either (f >>> Left) Right >>> h) q
            dimap' (ChanX   x q) = ChanX (dimap' <$> x) q
            dimap' (ChanZ     z) = ChanZ (dimap' <$> z)
            dimap' (Stop      r) = Stop r