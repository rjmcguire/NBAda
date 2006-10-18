pragma Style_Checks (Off);
-------------------------------------------------------------------------------
--                              -*- Mode: Ada -*-
--  Filename        : lock_free_sets.ads
--  Description     : Lock-free list-based sets based on Maged Michael,
--                    "High Performance Dynamic Lock-Free Hash Tables and
--                    List-Based Sets", The 14th Annual ACM Symposium on
--                    Parallel Algorithms and Architectures (SPAA'02),
--                    pages 73-82, August 2002.
--  Author          : Anders Gidenstam
--  Created On      : Fri Mar 10 11:54:37 2006
--  $Id: nbada-lock_free_sets.ads,v 1.2 2006/03/23 10:02:42 anders Exp $
-------------------------------------------------------------------------------
pragma Style_Checks (All_Checks);

pragma License (Modified_GPL);

with Process_Identification;

with Epoch_Based_Memory_Reclamation;
--  with Hazard_Pointers;

generic

   type Value_Type is private;
   type Key_Type is private;

   with function "<" (Left, Right : Key_Type) return Boolean is <>;
   --  Note: Key_Type must be totally ordered.

   with package Process_Ids is
     new Process_Identification (<>);
   --  Process identification.

package Lock_Free_Sets is

   ----------------------------------------------------------------------------
   --  Lock-free Set.
   ----------------------------------------------------------------------------
   type Set_Type is limited private;

   Not_Found       : exception;
   Already_Present : exception;

   procedure Init    (Set : in out Set_Type);

   procedure Insert  (Into  : in out Set_Type;
                      Key   : in     Key_Type;
                      Value : in     Value_Type);

   procedure Delete  (From : in out Set_Type;
                      Key  : in     Key_Type);

   function  Find    (Set : in Set_Type;
                      Key : in Key_Type) return Value_Type;

--  private

   package Memory_Reclamation_Scheme is
      new Epoch_Based_Memory_Reclamation (Process_Ids => Process_Ids);
--   package Memory_Reclamation_Scheme is
--      new Hazard_Pointers (Process_Ids                => Process_Ids,
--                           Max_Number_Of_Dereferences => 4);
   package MRS renames Memory_Reclamation_Scheme;

private

   type List_Node_Reference is new MRS.Shared_Reference_Base;

   type List_Node is new MRS.Managed_Node_Base with
      record
         Next  : aliased List_Node_Reference;
         pragma Atomic (Next);
         Key   : Key_Type;
         Value : Value_Type;
      end record;

   procedure Free     (Node : access List_Node);

   package MRS_Ops is new MRS.Reference_Operations (List_Node,
                                                    List_Node_Reference);

   subtype List_Node_Access is MRS_Ops.Private_Reference;

   type Set_Type is limited
      record
         Head : aliased List_Node_Reference;
         pragma Atomic (Head);
      end record;

end Lock_Free_Sets;