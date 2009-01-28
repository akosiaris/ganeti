{-| Module describing a node.

    All updates are functional (copy-based) and return a new node with
    updated value.
-}

module Node
    (
      Node(failN1, idx, f_mem, f_disk, slist, plist)
    -- * Constructor
    , create
    -- ** Finalization after data loading
    , buildPeers
    , setIdx
    -- * Instance (re)location
    , removePri
    , removeSec
    , addPri
    , addSec
    -- * Statistics
    , normUsed
    -- * Formatting
    , list
    ) where

import Data.List
import Text.Printf (printf)

import qualified Container
import qualified Instance
import qualified PeerMap

import Utils

data Node = Node { t_mem :: Int -- ^ total memory (Mib)
                 , f_mem :: Int -- ^ free memory (MiB)
                 , t_disk :: Int -- ^ total disk space (MiB)
                 , f_disk :: Int -- ^ free disk space (MiB)
                 , plist :: [Int] -- ^ list of primary instance indices
                 , slist :: [Int] -- ^ list of secondary instance indices
                 , idx :: Int -- ^ internal index for book-keeping
                 , peers:: PeerMap.PeerMap -- ^ primary node to instance
                                           -- mapping
                 , failN1:: Bool -- ^ whether the node has failed n1
                 , maxRes :: Int -- ^ maximum memory needed for
                                   -- failover by primaries of this node
  } deriving (Show)

{- | Create a new node.

The index and the peers maps are empty, and will be need to be update
later via the 'setIdx' and 'buildPeers' functions.

-}
create :: String -> String -> String -> String -> [Int] -> [Int] -> Node
create mem_t_init mem_f_init disk_t_init disk_f_init
       plist_init slist_init = Node
    {
      t_mem = read mem_t_init,
      f_mem = read mem_f_init,
      t_disk = read disk_t_init,
      f_disk = read disk_f_init,
      plist = plist_init,
      slist = slist_init,
      failN1 = True,
      idx = -1,
      peers = PeerMap.empty,
      maxRes = 0
    }

-- | Changes the index.
-- This is used only during the building of the data structures.
setIdx :: Node -> Int -> Node
setIdx t i = t {idx = i}

-- | Given the rmem, free memory and disk, computes the failn1 status.
computeFailN1 :: Int -> Int -> Int -> Bool
computeFailN1 new_rmem new_mem new_disk =
    new_mem <= new_rmem || new_disk <= 0


-- | Computes the maximum reserved memory for peers from a peer map.
computeMaxRes :: PeerMap.PeerMap -> PeerMap.Elem
computeMaxRes new_peers = PeerMap.maxElem new_peers

-- | Builds the peer map for a given node.
buildPeers :: Node -> Container.Container Instance.Instance -> Int -> Node
buildPeers t il num_nodes =
    let mdata = map
                (\i_idx -> let inst = Container.find i_idx il
                           in (Instance.pnode inst, Instance.mem inst))
                (slist t)
        pmap = PeerMap.accumArray (+) 0 (0, num_nodes - 1) mdata
        new_rmem = computeMaxRes pmap
        new_failN1 = computeFailN1 new_rmem (f_mem t) (f_disk t)
    in t {peers=pmap, failN1 = new_failN1, maxRes = new_rmem}

-- | Removes a primary instance.
removePri :: Node -> Instance.Instance -> Node
removePri t inst =
    let iname = Instance.idx inst
        new_plist = delete iname (plist t)
        new_mem = f_mem t + Instance.mem inst
        new_disk = f_disk t + Instance.disk inst
        new_failn1 = computeFailN1 (maxRes t) new_mem new_disk
    in t {plist = new_plist, f_mem = new_mem, f_disk = new_disk,
          failN1 = new_failn1}

-- | Removes a secondary instance.
removeSec :: Node -> Instance.Instance -> Node
removeSec t inst =
    let iname = Instance.idx inst
        pnode = Instance.pnode inst
        new_slist = delete iname (slist t)
        new_disk = f_disk t + Instance.disk inst
        old_peers = peers t
        old_peem = PeerMap.find pnode old_peers
        new_peem =  old_peem - (Instance.mem inst)
        new_peers = PeerMap.add pnode new_peem old_peers
        old_rmem = maxRes t
        new_rmem = if old_peem < old_rmem then
                       old_rmem
                   else
                       computeMaxRes new_peers
        new_failn1 = computeFailN1 new_rmem (f_mem t) new_disk
    in t {slist = new_slist, f_disk = new_disk, peers = new_peers,
          failN1 = new_failn1, maxRes = new_rmem}

-- | Adds a primary instance.
addPri :: Node -> Instance.Instance -> Maybe Node
addPri t inst =
    let iname = Instance.idx inst
        new_mem = f_mem t - Instance.mem inst
        new_disk = f_disk t - Instance.disk inst
        new_failn1 = computeFailN1 (maxRes t) new_mem new_disk in
      if new_failn1 then
        Nothing
      else
        let new_plist = iname:(plist t) in
        Just t {plist = new_plist, f_mem = new_mem, f_disk = new_disk,
                failN1 = new_failn1}

-- | Adds a secondary instance.
addSec :: Node -> Instance.Instance -> Int -> Maybe Node
addSec t inst pdx =
    let iname = Instance.idx inst
        old_peers = peers t
        new_disk = f_disk t - Instance.disk inst
        new_peem = PeerMap.find pdx old_peers + Instance.mem inst
        new_peers = PeerMap.add pdx new_peem old_peers
        new_rmem = max (maxRes t) new_peem
        new_failn1 = computeFailN1 new_rmem (f_mem t) new_disk in
    if new_failn1 then
        Nothing
    else
        let new_slist = iname:(slist t) in
        Just t {slist = new_slist, f_disk = new_disk,
                peers = new_peers, failN1 = new_failn1,
                maxRes = new_rmem}

-- | Simple converter to string.
str :: Node -> String
str t =
    printf ("Node %d (mem=%5d MiB, disk=%5.2f GiB)\n  Primaries:" ++
            " %s\nSecondaries: %s")
      (idx t) (f_mem t) ((f_disk t) `div` 1024)
      (commaJoin (map show (plist t)))
      (commaJoin (map show (slist t)))

-- | String converter for the node list functionality.
list :: String -> Node -> String
list n t =
    let pl = plist t
        sl = slist t
        (mp, dp) = normUsed t
    in
      printf "  %s(%d)\t%5d\t%5d\t%3d\t%3d\t%s\t%s\t%.5f\t%.5f"
                 n (idx t) (f_mem t) ((f_disk t) `div` 1024)
                 (length pl) (length sl)
                 (commaJoin (map show pl))
                 (commaJoin (map show sl))
                 mp dp

-- | Normalize the usage status
-- This converts the used memory and disk values into a normalized integer
-- value, currently expresed as per mille of totals

normUsed :: Node -> (Double, Double)
normUsed n =
    let mp = (fromIntegral $ f_mem n) / (fromIntegral $ t_mem n)
        dp = (fromIntegral $ f_disk n) / (fromIntegral $ t_disk n)
    in (mp, dp)
